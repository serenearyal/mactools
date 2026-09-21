import Darwin
import Foundation

import AwakeKit
import HelperProtocol

/// `ventctl awake`: the read side of Keep Awake, and a hold that takes the
/// same assertion the app takes.
///
/// The hold exists so the IOKit path can be checked without the GUI: run it,
/// look at `pmset -g assertions`, press Ctrl-C, look again.
enum AwakeCommands {
    @MainActor
    static func status() throws {
        let disabled = PowerAssertions.sleepDisabled()
        print("SleepDisabled  \(disabled.map { $0 ? "1 (this Mac never sleeps by itself)" : "0" } ?? "unknown")")
        print("\(ownership())")
        if disabled == true {
            print("               undo with: \(PowerAssertions.enableSleepCommand)")
        }
        let power = PowerSourceReader.read()
        print(
            "power          \(power.onBattery ? "battery" : "plugged in")"
                + (power.percent.map { ", \($0) %" } ?? "")
                + ", thermal \(thermalName(power.thermal))"
        )

        let entries = PowerAssertions.all()
        print("")
        guard !entries.isEmpty else {
            print("nothing is holding this Mac awake")
            return
        }
        print("\(pad("PROCESS", 26))\(pad("PID", 8))\(pad("TYPE", 34))NAME")
        for entry in entries {
            print(
                "\(pad(entry.processName, 26))\(pad("\(entry.pid)", 8))"
                    + "\(pad(entry.type, 34))\(entry.name)"
            )
        }
    }

    /// Takes the same assertion the app takes, with the same properties, and
    /// holds it until Ctrl-C.
    ///
    /// The name says "ventctl" rather than "Vent" so a `pmset -g assertions`
    /// tells the two apart; everything else about the assertion is identical,
    /// which is the point of the command.
    @MainActor
    static func hold(minutes: Int) throws {
        let duration: KeepAwakeDuration = minutes <= 0 ? .indefinite : .minutes(minutes)
        let request = AssertionRequest.make(
            duration: duration,
            keepDisplayOn: false,
            appName: "ventctl"
        )
        let backend = IOPMKeepAwakeBackend()
        if let failure = backend.create(request) { throw CLIError(failure) }
        print("holding: \(request.name) - \(request.details)")
        print("timeout: \(request.timeoutSeconds.map { "\($0) s" } ?? "none")")
        print("check with: pmset -g assertions | grep -i vent")
        print("Ctrl-C to release")

        // SIG_IGN first: the default action would kill the process before the
        // dispatch source ever runs, and the release below would never happen.
        // The kernel would drop the assertion anyway; this is what makes the
        // release visible, and what the app's quit path does too.
        signal(SIGINT, SIG_IGN)
        let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupts.setEventHandler {
            MainActor.assumeIsolated {
                backend.release()
                print("\nreleased")
                exit(0)
            }
        }
        interrupts.resume()

        // The timeout ends the assertion in the kernel; the process stays up
        // so the difference in `pmset` is visible either side of it.
        if let seconds = request.timeoutSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds) + 1) {
                print("the timeout has passed; the assertion is gone. Ctrl-C to exit")
            }
        }
        dispatchMain()
    }

    // MARK: - The lid

    /// Who set the flag, as far as the helper knows. The marker is root-owned,
    /// so without a helper this line says only that it could not be asked.
    private static func ownership() -> String {
        do {
            let report = try HelperCommands.sleepDisabledState()
            return switch report.owner {
            case .nobody: "set by        nobody"
            case .vent: "set by        Vent's helper, which clears it when the last client goes"
            case .somebodyElse: "set by        somebody else (pmset); Vent leaves it alone"
            }
        } catch {
            // A helper older than this build does not export the method at
            // all, so the connection drops mid-call and the reason reads like
            // a crash. Say what it usually is.
            let reason = (error as? CLIError)?.description ?? "\(error)"
            return "set by        unknown: \(reason)\n"
                + "               (a helper older than this build has no sleep method: reinstall it)"
        }
    }

    /// `ventctl awake lid on|off`: the same helper call the app's switch makes.
    ///
    /// The flag comes off again as soon as this process disconnects, which is
    /// the moment this command exits - the helper's restore guarantee. To see
    /// it held, turn the switch on in the app.
    static func lid(on: Bool) throws {
        try HelperCommands.setSleepDisabled(on)
        let report = try HelperCommands.sleepDisabledState()
        print("SleepDisabled  \(report.isSet ? "1" : "0")")
        print("owner          \(report.owner.rawValue)")
        guard on else { return }
        print(
            "note: the helper clears it when this command exits and its connection drops. "
                + "That is the safety guarantee, not a failure."
        )
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        MetricsCommands.pad(ScanCommands.middleTruncated(text, limit: width - 2), width)
    }
}
