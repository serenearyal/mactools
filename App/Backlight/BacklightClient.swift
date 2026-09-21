import BacklightKit
import Foundation

/// The handful of calls Vent makes into the keyboard backlight.
///
/// A protocol, so the rules above it can be tested against a fake: a test that
/// dims the real keyboard of whoever is running it is not a test.
@MainActor
protocol BacklightClient: AnyObject {
    /// Nil when the private framework and its class both loaded.
    var loadFailure: BacklightAvailability.Reason? { get }
    func keyboardIDs() -> [UInt64]
    func isBuiltIn(_ keyboard: UInt64) -> Bool
    /// 0...1.
    func brightness(_ keyboard: UInt64) -> Double
    func setBrightness(_ value: Double, _ keyboard: UInt64) -> Bool
    func isAutoEnabled(_ keyboard: UInt64) -> Bool
    func setAutoEnabled(_ enabled: Bool, _ keyboard: UInt64) -> Bool
    /// True in bright light, where the backlight is turned off on purpose.
    func isSuppressed(_ keyboard: UInt64) -> Bool
    /// True after a spell of no typing.
    func isDimmed(_ keyboard: UInt64) -> Bool
    /// False when the framework offers no usable change notification, which is
    /// the signal to fall back to polling while the slider is on screen.
    func observe(keyboard: UInt64, onChange: @escaping @MainActor @Sendable (String) -> Void) -> Bool
    func stopObserving()
}

/// What the backlight looks like right now, as one value.
struct BacklightReading: Equatable, Sendable {
    var level: Double = 0
    var isAuto = false
    var isSuppressed = false
    var isDimmed = false

    /// The one line under the slider, or nil when there is nothing to say.
    ///
    /// Suppressed beats dimmed: a keyboard the ambient sensor has switched off
    /// in bright light is not also "dimmed because you stopped typing".
    var stateNote: String? {
        if isSuppressed { return "Off right now: the room is bright enough." }
        if isDimmed { return "Dimmed: nothing has been typed for a while." }
        return nil
    }
}
