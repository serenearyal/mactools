import Foundation

import FanControl
import SMCKit

/// The fan side of the CLI. Every write goes through the helper, because only
/// root may touch the SMC write path.
enum FanCommands {
    // MARK: - Status

    static func status() throws {
        let snapshot = try HelperCommands.fanSnapshot()
        print(table(for: snapshot))
    }

    static func setAuto(_ argument: String?) throws {
        let snapshot = try HelperCommands.fanSnapshot()
        let indices: [Int]
        switch argument {
        case nil, "all":
            indices = snapshot.fans.map(\.index)
        case .some(let text):
            guard let index = Int(text), snapshot.fans.contains(where: { $0.index == index }) else {
                throw CLIError("'\(text)' is not a fan of this Mac; use an index or 'all'")
            }
            indices = [index]
        }
        for index in indices {
            try HelperCommands.setFanMode(.auto, forFan: index)
            print("fan \(index): auto")
        }
    }

    static func setConstant(index: Int, rpm: Int) throws {
        let snapshot = try HelperCommands.fanSnapshot()
        guard let fan = snapshot.fans.first(where: { $0.index == index }) else {
            throw CLIError("this Mac has no fan \(index)")
        }
        try HelperCommands.setFanMode(.constant(rpm: rpm), forFan: index)
        let clamped = FanSafety.clamp(Double(rpm), minimum: fan.minimumRPM, maximum: fan.maximumRPM)
        if let clamped, Int(clamped) != rpm {
            print("note: \(rpm) is outside \(Int(fan.minimumRPM))-\(Int(fan.maximumRPM)), clamped to \(Int(clamped))")
        }
        print(table(for: try HelperCommands.fanSnapshot()))
    }

    // MARK: - Self test

    /// The gentle live sequence: one fan to 2500 rpm, wait for it, back to
    /// Auto. It aborts on a hot CPU and restores Auto on every path out,
    /// including Ctrl-C.
    static func selftest() throws {
        let guardTemperature: Double = 85
        let target = 2500.0
        let tolerance = 300.0
        let settleSeconds = 20.0

        var rows: [(String, Bool, String)] = []
        installInterruptHandler()

        defer { restoreQuietly() }

        let start = try HelperCommands.fanSnapshot()
        print(table(for: start))
        guard let fan = start.fans.first else { throw CLIError("the helper reports no fan") }
        rows.append(("helper answers", true, "\(start.fans.count) fans"))

        let before = try hottestCPU()
        guard before < guardTemperature else {
            throw CLIError("the CPU is at \(format(before)) C, above the \(Int(guardTemperature)) C guard; not touching a fan")
        }
        rows.append(("CPU below \(Int(guardTemperature)) C", true, "\(format(before)) C"))

        print("setting fan \(fan.index) to \(Int(target)) rpm")
        try HelperCommands.setFanMode(.constant(rpm: Int(target)), forFan: fan.index)

        var reached = false
        var lastActual = fan.actualRPM
        let deadline = Date.now.addingTimeInterval(settleSeconds)
        while Date.now < deadline {
            Thread.sleep(forTimeInterval: 1)
            let snapshot = try HelperCommands.fanSnapshot()
            guard let live = snapshot.fans.first(where: { $0.index == fan.index }) else { break }
            lastActual = live.actualRPM
            let hottest = try hottestCPU()
            print("  \(Int(live.actualRPM)) rpm, target \(Int(live.targetRPM)), CPU \(format(hottest)) C")
            if hottest >= guardTemperature {
                throw CLIError("the CPU reached \(format(hottest)) C during the test; restoring Auto")
            }
            if abs(live.actualRPM - target) < tolerance {
                reached = true
                break
            }
        }
        rows.append((
            "fan reaches \(Int(target)) rpm",
            reached,
            "\(Int(lastActual)) rpm after at most \(Int(settleSeconds)) s"
        ))

        print("restoring Auto")
        try HelperCommands.setFanMode(.auto, forFan: fan.index)

        var backToAuto = false
        for _ in 0..<10 {
            let snapshot = try HelperCommands.fanSnapshot()
            if let live = snapshot.fans.first(where: { $0.index == fan.index }),
               live.hardwareMode == .auto, live.mode.isAuto {
                backToAuto = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        rows.append(("fan back on Auto", backToAuto, backToAuto ? "mode 0" : "still forced"))

        print("")
        for (name, passed, detail) in rows {
            print("\(passed ? "PASS" : "FAIL")  \(pad(name, 28))\(detail)")
        }
        print(table(for: try HelperCommands.fanSnapshot()))
        if rows.contains(where: { !$0.1 }) {
            throw CLIError("the fan self test did not pass")
        }
    }

    // MARK: - Helpers

    /// Ctrl-C during the test must not leave a forced fan. A dispatch source
    /// and not `signal()`: the restore is a blocking XPC call, which a C
    /// signal handler may not make.
    private static func installInterruptHandler() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            FileHandle.standardError.write(Data("\ninterrupted: restoring Auto\n".utf8))
            restoreQuietly()
            exit(130)
        }
        source.resume()
        interruptSource = source
    }

    /// Held for the life of the process; a cancelled source stops firing.
    nonisolated(unsafe) private static var interruptSource: DispatchSourceSignal?

    private static func restoreQuietly() {
        try? HelperCommands.restoreAllAuto()
    }

    private static func hottestCPU() throws -> Double {
        let connection = try SMCConnection()
        let keys = SensorNaming.knownTemperatureKeys(in: [.cpuPerformance, .cpuEfficiency])
        let readings = connection.readTemperatures(keys)
        guard let hottest = readings.map(\.celsius).max() else {
            throw CLIError("no CPU sensor is answering, so the temperature guard cannot run")
        }
        return hottest
    }

    static func table(for snapshot: FanSnapshot) -> String {
        var lines: [String] = []
        lines.append("\(pad("fan", 12))\(pad("rpm", 8))\(pad("min", 8))\(pad("max", 8))\(pad("target", 9))\(pad("hw", 9))mode")
        for fan in snapshot.fans {
            lines.append(
                pad(fan.name, 12)
                    + pad("\(Int(fan.actualRPM))", 8)
                    + pad("\(Int(fan.minimumRPM))", 8)
                    + pad("\(Int(fan.maximumRPM))", 8)
                    + pad("\(Int(fan.targetRPM))", 9)
                    + pad(fan.hardwareMode.rawValue, 9)
                    + fan.mode.summary
            )
        }
        if snapshot.interlockEngaged {
            let hottest = snapshot.hottestDieCelsius.map { " (\(format($0)) C)" } ?? ""
            lines.append("thermal interlock active\(hottest): every fan is on Auto")
        }
        for fault in snapshot.faults {
            lines.append("fault on fan \(fault.fanIndex): \(fault.reason)")
        }
        if let error = snapshot.readError {
            lines.append("read error: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
