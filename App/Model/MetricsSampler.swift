import Foundation
import SMCKit
import SysMetrics

/// Every reading of the app, taken off the main thread.
///
/// An actor, so the samplers and their delta state live on the cooperative
/// pool and the main actor only ever receives a finished `MetricsSample`.
///
/// Two things keep the cost down. The SMC key catalog is never loaded unless
/// the user asks for the unlabelled sensors, and every key info is read one
/// time and cached, so a periodic read is a single driver round trip per key
/// instead of two.
actor MetricsSampler {
    private let cpuSampler = CPUSampler()
    private let diskIOSampler = DiskIOSampler()

    private var connection: SMCConnection?
    private var connectionTried = false
    private var keyInfoCache: [SMCFourCC: SMCKeyInfo] = [:]
    /// Keys the machine does not answer. Read one time, skipped afterwards.
    private var deadKeys: Set<SMCFourCC> = []
    /// Fan count, minimum and maximum, read one time.
    private var fanLayout: [FanReading]?
    /// Which suffix this machine spells the fan mode register with, read one
    /// time with the layout. nil when it has none.
    private var fanModeSuffix: String?
    private var catalogTemperatureKeys: [SMCFourCC]?
    /// The purgeable share of the free space, per mount point, and when it was
    /// last read. See `volumes()`.
    private var purgeableBonus: [String: Int64] = [:]
    private var purgeableDate = Date.distantPast
    /// A minute. The purgeable space is an estimate of what the system would
    /// throw away under pressure; it moves in gigabytes over hours, and an
    /// hour-old number is still the right one to draw.
    private static let purgeableInterval: TimeInterval = 60

    var topology: CoreTopology { cpuSampler.topology }

    func sample(_ request: SampleRequest) -> MetricsSample {
        var sample = MetricsSample()

        if request.cpu {
            sample.cpu = try? cpuSampler.sample()
        }
        if request.memory {
            sample.memory = try? MemorySampler.sample()
        }
        if request.diskSpace {
            sample.volumes = volumes()
        }
        if request.diskIO {
            sample.diskIO = (try? diskIOSampler.sample())?.rates
        }
        if request.battery {
            // `batteryRead` and not the value: a Mac with no battery answers
            // nil for ever, and the store's floor has to move anyway.
            sample.batteryRead = true
            sample.battery = BatterySampler.read()
        }

        let needsSMC = request.temperatures != .none || request.fans || request.power != .none
        if needsSMC {
            sample.smcAvailable = smc() != nil
            if request.temperatures != .none {
                sample.temperatures = readTemperatures(request.temperatures)
                sample.temperatureScope = request.temperatures
            }
            if request.fans {
                sample.fans = readFans()
            }
            if request.power != .none {
                sample.power = readPower(request.power)
            }
        }
        return sample
    }

    // MARK: - Disks

    /// The mounted volumes, with the expensive part of the answer read once a
    /// minute.
    ///
    /// "Available" on a Mac is the free blocks plus whatever the system would
    /// purge for you, and that second half is a round trip to `cache_delete`
    /// that validates every volume through IOKit - it was the most expensive
    /// thing in a pass with the popover open. The free blocks are read every
    /// time, because a download has to show up at once; the purgeable share on
    /// top of them is carried over from the last full read.
    private func volumes() -> [VolumeInfo] {
        let now = Date.now
        if now.timeIntervalSince(purgeableDate) >= MetricsSampler.purgeableInterval {
            purgeableDate = now
            let full = DiskSpaceSampler.sample()
            purgeableBonus = Dictionary(
                full.map { ($0.mountPath, $0.purgeableBonus) },
                uniquingKeysWith: { first, _ in first }
            )
            return full
        }
        return DiskSpaceSampler.sample(includingPurgeableSpace: false).map { volume in
            guard let bonus = purgeableBonus[volume.mountPath] else { return volume }
            return volume.addingPurgeableBonus(bonus)
        }
    }

    // MARK: - SMC

    private func smc() -> SMCConnection? {
        if !connectionTried {
            connectionTried = true
            connection = try? SMCConnection()
        }
        return connection
    }

    /// One cached-key-info read. Returns nil once for a key the machine does
    /// not have, and never asks again.
    private func value(for key: SMCFourCC) -> Double? {
        guard !deadKeys.contains(key), let smc = smc() else { return nil }
        let info: SMCKeyInfo
        if let cached = keyInfoCache[key] {
            info = cached
        } else if let fresh = try? smc.keyInfo(for: key) {
            keyInfoCache[key] = fresh
            info = fresh
        } else {
            deadKeys.insert(key)
            return nil
        }
        guard let bytes = try? smc.readBytes(key, info: info) else { return nil }
        return info.type.decode(bytes).doubleValue
    }

    private func temperatureKeys(_ scope: TemperatureScope) -> [SMCFourCC] {
        switch scope {
        case .none:
            []
        case .cpu:
            SensorNaming.knownTemperatureKeys(in: [.cpuPerformance, .cpuEfficiency])
        case .cpuGPU:
            SensorNaming.knownTemperatureKeys(in: [.cpuPerformance, .cpuEfficiency, .gpu])
        case .labelled:
            SensorNaming.knownTemperatureKeys()
        case .everything:
            everyTemperatureKey()
        }
    }

    /// The only place that loads the key catalog, and only when the user asks
    /// for the unlabelled sensors. About 0.8 s, on the actor, one time.
    private func everyTemperatureKey() -> [SMCFourCC] {
        if let catalogTemperatureKeys { return catalogTemperatureKeys }
        guard let smc = smc(), let catalog = try? SMCKeyCatalog.load(from: smc) else {
            return SensorNaming.knownTemperatureKeys()
        }
        let keys = smc.temperatureKeys(in: catalog)
        catalogTemperatureKeys = keys
        return keys
    }

    private func readTemperatures(_ scope: TemperatureScope) -> [TemperatureReading] {
        temperatureKeys(scope).compactMap { key in
            guard let celsius = value(for: key),
                  SMCConnection.plausibleTemperatureRange.contains(celsius)
            else { return nil }
            let descriptor = SensorNaming.descriptor(for: key)
            return TemperatureReading(
                key: key,
                label: descriptor.label,
                category: descriptor.category,
                celsius: celsius
            )
        }
    }

    /// The first pass uses the full `readFans()` for the count and the limits,
    /// which do not change; later passes re-read the live keys.
    ///
    /// The mode register is one of them. It is what the firmware is doing right
    /// now, the helper or `ventctl` can change it from outside this process,
    /// and a cached copy would leave the Overview and the popover claiming Auto
    /// over a fan that is forced. The key info is cached, so it costs one
    /// driver round trip per fan.
    private func readFans() -> [FanReading] {
        guard let smc = smc() else { return [] }
        guard let layout = fanLayout else {
            let fans = (try? smc.readFans()) ?? []
            fanLayout = fans
            fanModeSuffix = (try? smc.fanCapabilities())?.modeSuffix
            return fans
        }
        return layout.map { fan in
            let actual = FanKeys.key(fan: fan.index, suffix: FanKeys.actual).flatMap { value(for: $0) }
            let target = FanKeys.key(fan: fan.index, suffix: FanKeys.target).flatMap { value(for: $0) }
            return FanReading(
                index: fan.index,
                actual: actual ?? fan.actual,
                minimum: fan.minimum,
                maximum: fan.maximum,
                target: target ?? fan.target,
                mode: mode(ofFan: fan.index) ?? fan.mode
            )
        }
    }

    private func mode(ofFan index: Int) -> SMCFanMode? {
        guard let suffix = fanModeSuffix,
              let key = FanKeys.key(fan: index, suffix: suffix),
              let value = value(for: key)
        else { return nil }
        return value == 0 ? .auto : .forced
    }

    private func readPower(_ scope: PowerScope) -> [PowerReading] {
        let keys: [SMCFourCC] = switch scope {
        case .none: []
        case .system: ["PSTR"]
        case .labelled: SensorNaming.knownPowerKeys
        }
        return keys.compactMap { key in
            guard let watts = value(for: key), watts.isFinite else { return nil }
            return PowerReading(key: key, label: SensorNaming.powerLabel(for: key), watts: watts)
        }
    }
}
