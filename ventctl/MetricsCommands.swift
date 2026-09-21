import Foundation

import SMCKit
import SysMetrics

enum MetricsCommands {
    /// One 1-second sample: nothing to compare against before that.
    static func cpu(interval: Double) throws {
        let sampler = CPUSampler()
        _ = try sampler.sample()
        Thread.sleep(forTimeInterval: interval)
        guard let sample = try sampler.sample() else {
            throw CLIError("no CPU tick moved in \(interval) s")
        }

        let levels = sampler.topology.levels
            .map { "\($0.name) \($0.logicalCount)" }
            .joined(separator: ", ")
        print("cores: \(sampler.topology.logicalCount) (\(levels))  interval: \(format(interval, 1)) s")
        print("total  \(percent(sample.total.busy))   user \(percent(sample.total.user))  sys \(percent(sample.total.system))  nice \(percent(sample.total.nice))  idle \(percent(sample.total.idle))")
        for (index, core) in sample.cores.enumerated() {
            print("  core \(pad("\(index)", 3)) \(sample.kind(ofCore: index).tag)  \(percent(core.busy))   user \(percent(core.user))  sys \(percent(core.system))  idle \(percent(core.idle))")
        }
    }

    static func memory() throws {
        let snapshot = try MemorySampler.sample()
        print("page size     \(MemorySampler.pageSize) bytes")
        print("total         \(bytes(snapshot.total))")
        print("used          \(bytes(snapshot.used))   \(percent(snapshot.usedFraction)) of total")
        print("  app         \(bytes(snapshot.app))")
        print("  wired       \(bytes(snapshot.wired))")
        print("  compressed  \(bytes(snapshot.compressed))")
        print("cached files  \(bytes(snapshot.cachedFiles))")
        print("free          \(bytes(snapshot.free))")
        print("swap          \(bytes(snapshot.swap.used)) of \(bytes(snapshot.swap.total))")
        print("pressure      \(snapshot.pressure?.label ?? "unknown")")
    }

    static func disks() throws {
        let volumes = DiskSpaceSampler.sample()
        guard !volumes.isEmpty else { throw CLIError("no mounted volume reports a capacity") }
        for volume in volumes {
            let tags = [
                volume.isBootVolume ? "boot" : nil,
                volume.isInternal ? "internal" : "external",
                volume.isRemovable ? "removable" : nil,
            ].compactMap { $0 }.joined(separator: ", ")
            print("\(volume.name)  (\(tags))")
            print("  mount       \(volume.mountPath)  \(volume.fileSystemType)  \(volume.device)")
            print("  \(bytes(volume.used)) of \(bytes(volume.total)) used  (\(percent(volume.usedFraction)))")
            print("  available   \(bytes(volume.available))  raw \(bytes(volume.availableRaw))")
        }
    }

    static func io(interval: Double) throws {
        let sampler = DiskIOSampler()
        let first = try sampler.sample()
        Thread.sleep(forTimeInterval: interval)
        let second = try sampler.sample()
        guard let rates = second.rates else { throw CLIError("no disk I/O delta over \(interval) s") }

        print("interval  \(format(rates.interval, 2)) s")
        print("read      \(rate(rates.bytesReadPerSecond))   \(format(rates.readsPerSecond, 1)) ops/s")
        print("write     \(rate(rates.bytesWrittenPerSecond))   \(format(rates.writesPerSecond, 1)) ops/s")
        print("totals    read \(bytes(second.total.bytesRead))  written \(bytes(second.total.bytesWritten))")
        for name in second.devices.keys.sorted() {
            let current = second.devices[name] ?? .zero
            let previous = first.devices[name] ?? .zero
            guard let device = DiskIOMath.rates(from: previous, to: current, seconds: rates.interval) else {
                continue
            }
            print("  \(pad(name, 10)) read \(rate(device.bytesReadPerSecond))  write \(rate(device.bytesWrittenPerSecond))")
        }
    }

    /// `--helper` merges the snapshot of the privileged helper into the local
    /// pass, which is the only way to see the CPU and memory of a process this
    /// user does not own. Two helper calls, so its CPU deltas cover the same
    /// interval as the local ones.
    static func processes(sort: ProcessSort, top: Int, interval: Double, useHelper: Bool) throws {
        let sampler = ProcessSampler()
        _ = try sampler.sample()
        var helperFailure: String?
        if useHelper {
            do {
                _ = try HelperCommands.processSnapshot()
            } catch {
                helperFailure = "\(error)"
            }
        }
        Thread.sleep(forTimeInterval: interval)
        // The second pass is the one with CPU percentages; sort that one
        // rather than sampling a third time.
        var all = try sampler.sample()
        guard !all.isEmpty else { throw CLIError("the process table is empty") }
        var privileged: [ProcessInfoRow] = []
        if useHelper, helperFailure == nil {
            do {
                privileged = try HelperCommands.processSnapshot()
                all = ProcessSampler.merge(local: all, privileged: privileged)
            } catch {
                helperFailure = "\(error)"
            }
        }
        let rows = switch sort {
        case .cpu: ProcessSampler.topByCPU(all, count: top)
        case .memory: ProcessSampler.topByMemory(all, count: top)
        }

        print("\(pad("PID", 8))\(pad("PPID", 8))\(pad("UID", 7))\(pad("CPU%", 9))\(pad("MEMORY", 12))NAME")
        for row in rows {
            let cpu = row.cpuPercent.map { format($0, 1) } ?? "-"
            let memory = row.memoryBytes.map { bytes($0) } ?? "-"
            print("\(pad("\(row.pid)", 8))\(pad("\(row.parentPID)", 8))\(pad("\(row.uid)", 7))\(pad(cpu, 9))\(pad(memory, 12))\(row.name)")
        }
        print("\n\(all.count) processes, \(all.count { $0.isRestricted }) refuse their counters without root")
        if useHelper {
            if let helperFailure {
                print("helper: \(helperFailure)")
            } else {
                print("helper: \(privileged.count) rows merged")
            }
        }
    }

    /// Every field of one battery reading, for comparing against `pmset -g
    /// batt` and `system_profiler SPPowerDataType`.
    ///
    /// A field that is not there prints as a dash: an external battery and a
    /// Mac in a virtual machine answer the `IOPS` half and publish no
    /// `AppleSmartBattery` entry at all.
    static func battery() throws {
        guard let reading = BatterySampler.read() else {
            throw CLIError("this Mac has no battery")
        }
        let time = reading.minutesRemaining.map { minutes in
            "\(minutes / 60)h \(minutes % 60)m (\(minutes) min)"
        } ?? "calculating"
        print("state          \(reading.stateDescription)")
        print("charge         \(reading.percent) %")
        print("plugged in     \(reading.isPluggedIn ? "yes" : "no")")
        print("charging       \(reading.isCharging ? "yes" : "no")")
        print("charged        \(reading.isCharged ? "yes" : "no")")
        print("time \(reading.isCharging ? "to full  " : "remaining") \(time)")
        print("cycles         \(reading.cycleCount.map(String.init) ?? "-")")
        print("health         \(reading.healthPercent.map { "\($0) %" } ?? "-")")
        print("temperature    \(reading.temperatureCelsius.map { format($0, 2) + " C" } ?? "-")")
        print("power          \(reading.watts.map { format($0, 2) + " W" } ?? "-")  (positive is into the battery)")
        print("adapter        \(reading.adapterWatts.map { "\($0) W" } ?? "-")")
        print("low power mode \(reading.lowPowerMode ? "on" : "off")")
    }

    /// One line per tick until Ctrl-C. The SMC catalog load costs about a
    /// second, so it happens once before the loop.
    static func watch(interval: Double) throws {
        // stdout is block-buffered when it is a pipe or a file, which would
        // hold a stream back for minutes. Line buffering makes `ventctl
        // watch | tee` behave like the terminal.
        setvbuf(stdout, nil, _IOLBF, 0)

        let cpuSampler = CPUSampler()
        let ioSampler = DiskIOSampler()
        let connection = try? SMCConnection()
        let temperatureKeys: [SMCFourCC] = connection.map { open in
            let catalog = (try? SMCKeyCatalog.load(from: open)) ?? SMCKeyCatalog(entries: [], reportedCount: 0)
            return open.temperatureKeys(in: catalog).filter { key in
                let category = SensorNaming.descriptor(for: key).category
                return category == .cpuPerformance || category == .cpuEfficiency
            }
        } ?? []

        _ = try cpuSampler.sample()
        _ = try ioSampler.sample()

        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        print("watching every \(format(interval, 1)) s, Ctrl-C to stop")
        while true {
            Thread.sleep(forTimeInterval: interval)
            let cpu = try cpuSampler.sample()
            let memory = try MemorySampler.sample()
            let disk = try ioSampler.sample()
            let watts = connection.flatMap { (try? $0.readDouble("PSTR")) ?? nil }
            let hottest = connection
                .map { $0.readTemperatures(temperatureKeys) }?
                .max { $0.celsius < $1.celsius }

            let fields = [
                clock.string(from: Date()),
                "cpu \(pad(percent(cpu?.total.busy ?? 0), 7))",
                "mem \(pad(bytes(memory.used), 10)) of \(bytes(memory.total))",
                "io r \(pad(rate(disk.rates?.bytesReadPerSecond ?? 0), 12)) w \(pad(rate(disk.rates?.bytesWrittenPerSecond ?? 0), 12))",
                "power \(pad(watts.map { format($0, 2) + " W" } ?? "-", 9))",
                "cpu temp \(hottest.map { format($0.celsius, 1) + " C" } ?? "-")",
            ]
            print(fields.joined(separator: "  "))
        }
    }

    // MARK: - formatting

    /// Decimal units, the same convention Finder and Activity Monitor use.
    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1000, unit < units.count - 1 {
            amount /= 1000
            unit += 1
        }
        return "\(format(amount, unit == 0 ? 0 : 2)) \(units[unit])"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        "\(bytes(UInt64(max(0, bytesPerSecond.rounded()))))/s"
    }

    static func percent(_ fraction: Double) -> String { "\(format(fraction * 100, 1)) %" }

    static func format(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}

enum ProcessSort: String {
    case cpu
    case memory = "mem"
}
