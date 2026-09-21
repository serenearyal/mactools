import Foundation

import SysMetrics

/// `mactoolsctl energy`: the apps using the most CPU energy, over a window the
/// command measures for itself.
///
/// The counter is `ri_energy_nj` of `proc_pid_rusage`, which the app reads in
/// exactly the same pass that gives the process table its CPU and memory, so
/// this command proves the app's own arithmetic rather than a copy of it.
enum EnergyCommands {
    /// Two passes of the process table, `interval` apart, through the same
    /// `AppEnergyWindow` the Battery tab uses.
    ///
    /// `--helper` merges the privileged snapshot into both passes: a root-owned
    /// process refuses `proc_pid_rusage`, so without it `kernel_task`,
    /// `WindowServer` and every daemon are simply absent from the list.
    static func top(interval: Double, count: Int, useHelper: Bool) throws {
        let sampler = ProcessSampler()
        var window = AppEnergyWindow()
        var helperFailure: String?
        var helperRows = 0

        func pass() throws -> [ProcessInfoRow] {
            var rows = try sampler.sample()
            guard useHelper, helperFailure == nil else { return rows }
            do {
                let privileged = try HelperCommands.processSnapshot()
                helperRows = privileged.count
                rows = ProcessSampler.merge(local: rows, privileged: privileged)
            } catch {
                helperFailure = "\(error)"
            }
            return rows
        }

        window.add(try pass(), at: Date())
        Thread.sleep(forTimeInterval: interval)
        let rows = try pass()
        window.add(rows, at: Date())

        let apps = window.topApps(limit: count)
        guard !apps.isEmpty else {
            throw CLIError("no process burned measurable energy over \(MetricsCommands.format(interval, 1)) s")
        }
        // Every app the window saw, so the total is the whole measured draw and
        // not the part the top rows explain.
        let all = window.topApps(limit: .max)
        let totalWatts = all.reduce(0) { $0 + $1.watts }

        print("window    \(MetricsCommands.format(window.coveredSeconds, 2)) s")
        print("processes \(rows.count), \(rows.count { $0.energyNanojoules == nil }) without a readable energy counter")
        print("")
        print("\(MetricsCommands.pad("WATTS", 9))\(MetricsCommands.pad("SHARE", 8))\(MetricsCommands.pad("PROCS", 7))NAME")
        for app in apps {
            print(
                MetricsCommands.pad(MetricsCommands.format(app.watts, 3), 9)
                    + MetricsCommands.pad(MetricsCommands.format(app.share * 100, 1) + " %", 8)
                    + MetricsCommands.pad("\(app.processCount)", 7)
                    + app.name
            )
        }
        print("")
        print("\(all.count) apps burned energy; all of them together \(MetricsCommands.format(totalWatts, 2)) W of CPU")
        printBatteryComparison(totalWatts: totalWatts)
        if useHelper {
            print(helperFailure.map { "helper: \($0)" } ?? "helper: \(helperRows) rows merged")
        } else {
            print("root-owned processes are absent: they refuse proc_pid_rusage. Add --helper for them.")
        }
    }

    /// What the battery says it is losing, next to what the processes explain.
    ///
    /// The two are not the same quantity and the command says so: the process
    /// counters are CPU energy, and the battery pays for the display, the
    /// radios, the SSD and everything else as well.
    private static func printBatteryComparison(totalWatts: Double) {
        guard let reading = BatterySampler.read(), let watts = reading.watts else {
            print("battery: no reading, so there is nothing to compare the total against")
            return
        }
        let flow = watts < 0
            ? "discharging at \(MetricsCommands.format(-watts, 2)) W"
            : "charging at \(MetricsCommands.format(watts, 2)) W"
        print("battery: \(flow) (\(reading.stateDescription))")
        guard watts < 0 else {
            print("on the adapter the battery draw says nothing about what the processes cost")
            return
        }
        let share = totalWatts / -watts * 100
        print(
            """
            the CPU energy of the processes is \(MetricsCommands.format(share, 0)) % of that draw; \
            the rest is the display, the radios and everything else
            """
        )
    }
}
