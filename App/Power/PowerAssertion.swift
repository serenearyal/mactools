import AwakeKit
import Foundation
import IOKit.pwr_mgt

/// What the state machine needs from the power manager.
///
/// A protocol because the only honest test of the state machine is one that
/// never takes an assertion: a unit test that holds a real Mac awake for the
/// length of the suite is a bug, not a test.
@MainActor
protocol KeepAwakeBackend: AnyObject {
    /// Nil on success, the reason on failure.
    func create(_ request: AssertionRequest) -> String?
    /// Idempotent: releasing nothing is not an error.
    func release()
    var isHolding: Bool { get }
}

/// `IOPMAssertionCreateWithProperties`, the real thing.
///
/// One or two assertions: `PreventUserIdleSystemSleep` always, and
/// `PreventUserIdleDisplaySleep` beside it when the user asked for the display
/// to stay on. They are separate assertions because the kernel treats them as
/// separate types; one cannot carry both.
///
/// The timeout goes into the same call, so the kernel ends it even if the app
/// is killed. An assertion dies with its process, so a crash needs no cleanup
/// at all - the release on quit only makes it immediate.
@MainActor
final class IOPMKeepAwakeBackend: KeepAwakeBackend {
    private var ids: [IOPMAssertionID] = []

    var isHolding: Bool { !ids.isEmpty }

    func create(_ request: AssertionRequest) -> String? {
        release()
        var types: [String] = []
        if request.systemSleep { types.append(kIOPMAssertionTypePreventUserIdleSystemSleep) }
        if request.displaySleep { types.append(kIOPMAssertionTypePreventUserIdleDisplaySleep) }
        guard !types.isEmpty else { return "nothing to assert" }

        for type in types {
            var properties: [String: Any] = [
                kIOPMAssertionTypeKey: type,
                kIOPMAssertionNameKey: request.name,
                kIOPMAssertionDetailsKey: request.details,
                kIOPMAssertionLevelKey: Int(kIOPMAssertionLevelOn),
            ]
            if let timeout = request.timeoutSeconds {
                properties[kIOPMAssertionTimeoutKey] = timeout
                // Release, not turn off: a timed-out assertion that lingers in
                // `pmset -g assertions` as "off" is noise in a list the Keep
                // Awake tab shows to the user.
                properties[kIOPMAssertionTimeoutActionKey] = kIOPMAssertionTimeoutActionRelease
            }
            var id: IOPMAssertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
            guard result == kIOReturnSuccess else {
                release()
                return "the power manager refused the assertion (0x\(String(result, radix: 16)))"
            }
            ids.append(id)
        }
        AppLog.app.notice(
            """
            keep awake on: \(request.name, privacy: .public), \
            display \(request.displaySleep, privacy: .public), \
            timeout \(request.timeoutSeconds.map(String.init) ?? "none", privacy: .public)
            """
        )
        return nil
    }

    func release() {
        guard !ids.isEmpty else { return }
        for id in ids { IOPMAssertionRelease(id) }
        ids = []
        AppLog.app.notice("keep awake off: assertions released")
    }
}

/// One assertion somebody on this Mac is holding, for the list on the tab.
struct AssertionEntry: Identifiable, Equatable, Sendable {
    let id: String
    let processName: String
    let pid: Int32
    /// The raw `AssertType`, for example `PreventUserIdleSystemSleep`.
    let type: String
    let name: String

    /// The type in words. A user reading "NoDisplaySleepAssertion" learns
    /// nothing; "keeps the display on" is the whole point of the list.
    var plainType: String {
        switch type {
        case kIOPMAssertionTypePreventUserIdleSystemSleep, "NoIdleSleepAssertion":
            "keeps this Mac awake"
        case kIOPMAssertionTypePreventUserIdleDisplaySleep, "NoDisplaySleepAssertion":
            "keeps the display on"
        case kIOPMAssertionTypePreventSystemSleep:
            "keeps this Mac awake while plugged in"
        case kIOPMAssertionTypeNoIdleSleep:
            "prevents idle sleep"
        case "UserIsActive":
            "reports that somebody is using this Mac"
        case "InternalPreventDisplaySleep":
            "keeps the display on (system)"
        case "PreventDiskIdle":
            "keeps the disk spinning"
        case "BackgroundTask":
            "is finishing a background task"
        case "ApplePushServiceTask":
            "is waiting for a push notification"
        case "NetworkClientActive":
            "is keeping the network awake"
        default:
            type
        }
    }
}

/// The two read-only power questions the Keep Awake tab asks the system.
enum PowerAssertions {
    /// Everything holding this Mac awake, from `IOPMCopyAssertionsByProcess`.
    ///
    /// No root needed, and cheap: one CF dictionary, a few hundred entries at
    /// worst. The tab reads it every five seconds and only while it is on
    /// screen.
    static func all() -> [AssertionEntry] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let raw = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }

        var entries: [AssertionEntry] = []
        for (pid, list) in raw {
            for assertion in list {
                let type = assertion[kIOPMAssertionTypeKey] as? String ?? "unknown"
                let name = assertion[kIOPMAssertionNameKey] as? String ?? ""
                let process = assertion["Process Name"] as? String ?? "pid \(pid.int32Value)"
                entries.append(
                    AssertionEntry(
                        // The id of the assertion itself, so a list that
                        // refreshes does not reshuffle rows that did not move.
                        id: "\(pid.int32Value)-\(assertion["AssertionId"].map { "\($0)" } ?? name)",
                        processName: process,
                        pid: pid.int32Value,
                        type: type,
                        name: name
                    )
                )
            }
        }
        // By process, then by type: the same Mac gives the same list twice.
        return entries.sorted {
            if $0.processName.lowercased() != $1.processName.lowercased() {
                return $0.processName.lowercased() < $1.processName.lowercased()
            }
            if $0.type != $1.type { return $0.type < $1.type }
            return $0.name < $1.name
        }
    }

    /// True when somebody has run `sudo pmset disablesleep 1`.
    ///
    /// This is not an assertion: it is a system setting that stops the Mac
    /// sleeping at all, and it survives a reboot. Vent never sets it, and it
    /// would be dishonest to show a Keep Awake switch without saying that the
    /// Mac is already held awake by something else.
    ///
    /// `IOPMCopySystemPowerSettings` is exported by IOKit but declared in no
    /// public header, so it is reached through `dlsym` rather than by
    /// redeclaring the symbol: a wrong redeclaration is a link error at best
    /// and a crash at worst. Parsing `pmset -g` would mean a subprocess on
    /// every read for the same one integer.
    static func sleepDisabled() -> Bool? {
        typealias Copy = @convention(c) () -> Unmanaged<CFDictionary>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPMCopySystemPowerSettings")
        else { return nil }
        let copy = unsafeBitCast(symbol, to: Copy.self)
        guard let settings = copy()?.takeRetainedValue() as? [String: Any] else { return nil }
        guard let value = settings["SleepDisabled"] as? NSNumber else { return false }
        return value.boolValue
    }

    /// What the user would type to undo it. Shown as selectable text with a
    /// copy button, never run by Vent: it needs root, and a Mac that cannot
    /// sleep is the user's own decision to reverse.
    static let enableSleepCommand = "sudo pmset disablesleep 0"
}
