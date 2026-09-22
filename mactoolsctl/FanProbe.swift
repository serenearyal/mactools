import Foundation

import SMCKit

/// A root-only diagnostic that talks to the SMC directly, with no helper in
/// between: force fan 0 to a speed (2500 rpm unless one is given, and 0 is
/// allowed, to see if the SMC holds a fan stopped), print what the mode, target and actual
/// keys read back over time, then hand the fan back. It answers how long the
/// SMC takes to show a written setpoint. Run it as `sudo mactoolsctl fan-probe [rpm]`.
enum FanProbe {
    static let defaultRPM = 2500
    /// Above the maximum of any Apple silicon fan; the SMC clamps to its own.
    static let maximumRPM = 8000

    nonisolated(unsafe) private static var interruptSource: DispatchSourceSignal?

    static func run(rpm: Int) throws {
        guard geteuid() == 0 else { throw CLIError("'fan-probe' writes to the SMC; run it with sudo") }
        let smc = try SMCConnection()
        // Every labelled CPU sensor, finite values only; it throws when none
        // answers, so the guard never passes on a missing reading.
        let hottest = try FanCommands.hottestCPU()
        guard hottest < 85 else { throw CLIError("the CPU is at \(Int(hottest)) C; not forcing a fan now") }

        let restore: @Sendable () -> Void = {
            try? smc.write(.number(0), to: "F0Md")
            try? smc.write(.number(0), to: "F0Tg")
        }
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            restore()
            exit(130)
        }
        source.resume()
        interruptSource = source
        defer { restore() }

        func line(_ label: String, since start: Date) {
            let values = ["F0Md", "F0Tg", "F0Ac"].map { key -> String in
                let value = SMCFourCC(code: key).flatMap { try? smc.read($0).value.doubleValue }
                return "\(key)=\(value.map { String(Int($0.rounded())) } ?? "?")"
            }
            let elapsed = String(format: "%6.2f s", Date().timeIntervalSince(start))
            print("\(elapsed)  \(label.padding(toLength: 14, withPad: " ", startingAt: 0)) \(values.joined(separator: "  "))")
        }

        let start = Date()
        line("before", since: start)
        try smc.write(.number(1), to: "F0Md")
        line("mode written", since: start)
        try smc.write(.number(Double(rpm)), to: "F0Tg")
        line("target written", since: start)
        for step in 1...80 {
            Thread.sleep(forTimeInterval: step <= 20 ? 0.05 : 0.2)
            line("", since: start)
        }
        restore()
        line("auto written", since: start)
        for _ in 1...10 {
            Thread.sleep(forTimeInterval: 0.3)
            line("", since: start)
        }
    }
}
