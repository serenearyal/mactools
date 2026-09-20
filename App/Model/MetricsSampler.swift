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
    private let processSampler = ProcessSampler()

    private var connection: SMCConnection?
    private var connectionTried = false
    private var keyInfoCache: [SMCFourCC: SMCKeyInfo] = [:]
    /// Keys the machine does not answer. Read one time, skipped afterwards.
    private var deadKeys: Set<SMCFourCC> = []
    /// Fan count, minimum and maximum, read one time.
    private var fanLayout: [FanReading]?
    private var catalogTemperatureKeys: [SMCFourCC]?

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
            sample.volumes = DiskSpaceSampler.sample()
        }
        if request.diskIO {
            sample.diskIO = (try? diskIOSampler.sample())?.rates
        }

        let needsSMC = request.temperatures != .none || request.fans || request.power != .none
        if needsSMC {
            sample.smcAvailable = smc() != nil
            if request.temperatures != .none {
                sample.temperatures = readTemperatures(request.temperatures)
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

    func sampleProcesses() -> [ProcessInfoRow] {
        (try? processSampler.sample()) ?? []
    }

    /// Frees the per-process CPU baselines while the process list is hidden.
    func resetProcesses() {
        processSampler.reset()
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

    /// The first pass uses the full `readFans()` for the count, the limits and
    /// the mode; later passes only re-read the live RPM keys.
    private func readFans() -> [FanReading] {
        guard let smc = smc() else { return [] }
        guard let layout = fanLayout else {
            let fans = (try? smc.readFans()) ?? []
            fanLayout = fans
            return fans
        }
        return layout.map { fan in
            let actual = FanKeys.key(fan: fan.index, suffix: "Ac").flatMap { value(for: $0) }
            let target = FanKeys.key(fan: fan.index, suffix: "Tg").flatMap { value(for: $0) }
            return FanReading(
                index: fan.index,
                actual: actual ?? fan.actual,
                minimum: fan.minimum,
                maximum: fan.maximum,
                target: target ?? fan.target,
                mode: fan.mode
            )
        }
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
