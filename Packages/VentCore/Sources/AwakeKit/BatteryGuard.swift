import Foundation

/// Keeps a forgotten Keep Awake from flattening the battery.
///
/// Only the guard's own release may be undone: if the user turned Keep Awake
/// off, plugging the Mac in must not turn it back on.
public enum BatteryGuard {
    public enum Decision: Sendable, Equatable {
        /// Nothing changes.
        case keep
        /// Release the assertion now, and remember that the guard did it.
        case release
        /// The reason is gone: the app may take the assertion again.
        case mayRestore
    }

    /// The charge has to climb this far above the threshold before the guard
    /// gives the assertion back, so a battery sitting on the line does not
    /// flap.
    public static let hysteresis = 3

    public static func decide(
        onBattery: Bool,
        percent: Int,
        threshold: Int,
        isOn: Bool,
        wasReleasedByGuard: Bool,
        thermal: ProcessInfo.ThermalState = .nominal
    ) -> Decision {
        // A critical thermal state beats everything: a Mac that hot must be
        // allowed to sleep, however it is powered.
        if thermal == .critical {
            return isOn ? .release : .keep
        }

        guard onBattery else {
            return !isOn && wasReleasedByGuard ? .mayRestore : .keep
        }

        if isOn {
            return percent <= threshold ? .release : .keep
        }
        guard wasReleasedByGuard else { return .keep }
        return percent >= threshold + hysteresis ? .mayRestore : .keep
    }
}
