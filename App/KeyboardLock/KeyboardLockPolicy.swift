import CoreGraphics
import Foundation

/// The pure rules of the keyboard lock: what the tap asks for, what it
/// swallows, when the escape chord fires, how long a hold takes and what a
/// timeout may be set to.
///
/// No AppKit and no state of the running app, so the integration test target
/// compiles this file directly and checks every rule without a tap.

// MARK: - Event mask

enum LockEventMask {
    /// `NX_SYSDEFINED` from `IOKit/hidsystem/IOLLEvent.h`. `CGEventType` has
    /// no case for it, so the literal 14 is the only way to name the type.
    /// These events carry the media and special keys of the top row, which a
    /// plain keyDown mask would let through.
    static let systemDefinedType: UInt32 = 14

    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`. Only this subtype is swallowed.
    /// Subtype 7 is `NX_SUBTYPE_AUX_MOUSE_BUTTONS`, which reports the state
    /// of the mouse buttons, and the mouse is the unlock path, so every other
    /// subtype is passed through untouched.
    static let auxControlButtonsSubtype = 8

    static let value: CGEventMask =
        (CGEventMask(1) << CGEventType.keyDown.rawValue)
        | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        | (CGEventMask(1) << systemDefinedType)

    static func swallowsSystemDefined(subtype: Int) -> Bool {
        subtype == auxControlButtonsSubtype
    }
}

// MARK: - Permissions

/// The three permissions that decide whether a lock can start.
struct LockPermissions: Equatable {
    var accessibility = false
    var inputMonitoring = false
    /// True while another app holds Secure Keyboard Entry. No tap sees a key
    /// then, so the lock would be a lie.
    var secureInputEnabled = false

    var canLock: Bool { accessibility && inputMonitoring && !secureInputEnabled }
}

// MARK: - Recovering from a refusal

/// What a fresh permission read means for a lock that was refused.
///
/// The three permissions are granted in System Settings, outside the app, and
/// the controller re-reads them on every activation. Without this rule the
/// refusal stayed on screen for the rest of the session: the user granted what
/// was missing, came back, and the tab still said MacTools could not hold the
/// keyboard.
enum LockRecovery {
    /// True when a refused lock may be offered again: the state is a failure
    /// and every permission it needs is now there.
    static func clearsFailure(isFailed: Bool, permissions: LockPermissions) -> Bool {
        isFailed && permissions.canLock
    }
}

// MARK: - Escape chord

/// Three Escape key-downs inside a sliding 2 s window.
///
/// The window slides: presses older than 2 s are dropped, so a slow first
/// press does not ruin the two that follow.
///
/// Other keys are deliberately ignored rather than treated as a reset. The
/// lock exists for wiping a keyboard, so while it runs dozens of keys are
/// held down by a cloth; a reset on any other key would make the escape path
/// useless exactly when the user needs it.
struct UnlockChord {
    static let requiredPresses = 3
    static let window: TimeInterval = 2
    /// `kVK_Escape`.
    static let escapeKeyCode: Int64 = 53

    private var presses: [TimeInterval] = []

    init() {}

    /// Returns true when this press completes the chord.
    mutating func registerEscape(at now: TimeInterval) -> Bool {
        presses.removeAll { now - $0 > UnlockChord.window }
        presses.append(now)
        guard presses.count >= UnlockChord.requiredPresses else { return false }
        presses.removeAll()
        return true
    }
}

// MARK: - Hold to unlock

/// The hold-to-unlock button. A short tap must never unlock: a cleaning cloth
/// dragged over the trackpad clicks it constantly.
enum HoldToUnlock {
    static let duration: TimeInterval = 1.5

    static func progress(elapsed: TimeInterval) -> Double {
        min(max(elapsed / duration, 0), 1)
    }

    static func isComplete(elapsed: TimeInterval) -> Bool {
        elapsed >= duration
    }
}

// MARK: - Auto timeout

/// The hard timeout that always ends the lock.
enum LockTimeout {
    static let range: ClosedRange<Int> = 15...300
    static let `default` = 60
    /// A debug `--lock-test` run may never hold the keyboard longer than this.
    static let debugMaximum = 10

    static let choices = [15, 30, 60, 120, 180, 300]

    static func clamp(_ seconds: Int) -> Int {
        min(max(seconds, range.lowerBound), range.upperBound)
    }

    static func clampDebug(_ seconds: Int) -> Int {
        min(max(seconds, 1), debugMaximum)
    }

    static func title(_ seconds: Int) -> String {
        seconds < 60
            ? "\(seconds) s"
            : (seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s")
    }
}
