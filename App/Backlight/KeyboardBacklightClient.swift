import BacklightKit
import Foundation
import ObjectiveC

/// `CoreBrightness.framework`, reached the only way it can be reached.
///
/// The framework is private: there is no header, no import and no stable
/// symbol to link against, so every step is looked up at runtime and every
/// step may fail on a macOS MacTools has never seen. Nothing here traps; a missing
/// class or a missing method makes the whole feature unavailable, and the
/// section disappears rather than showing a dead slider.
///
/// The calls go through `method_getImplementation` and a typed
/// `@convention(c)` pointer rather than `perform(_:)`: two of them take a
/// `Float` and one takes a `_Bool`, and `NSInvocation`-style dispatch gets
/// both wrong on arm64, where floats travel in their own registers.
///
/// The type encodings below are read off this Mac with
/// `class_copyMethodList` + `method_getTypeEncoding`, not guessed:
///
///     copyKeyboardBacklightIDs            @16@0:8
///     brightnessForKeyboard:              f24@0:8Q16
///     setBrightness:forKeyboard:          B28@0:8f16Q20
///     isAutoBrightnessEnabledForKeyboard: B24@0:8Q16
///     enableAutoBrightness:forKeyboard:   B28@0:8B16Q20
///     isKeyboardBuiltIn:                  B24@0:8Q16
///     isBacklightSuppressedOnKeyboard:    B24@0:8Q16
///     isBacklightDimmedOnKeyboard:        B24@0:8Q16
///     registerNotificationForKeys:keyboardID:block:  v40@0:8@16Q24@?32
///
/// The hardened runtime is the real gate: a Release build with a
/// library-validation exception would be a signing mistake, and an Apple
/// platform binary needs none, so the Release app loading this is the proof.
@MainActor
final class KeyboardBacklightClient: BacklightClient {
    private typealias CopyIDs = @convention(c) (AnyObject, Selector) -> NSArray?
    private typealias FloatForID = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias BoolForID = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias SetFloat = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias SetBool = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool
    private typealias Register = @convention(c) (
        AnyObject, Selector, NSArray, UInt64, @convention(block) (NSString, Any?) -> Void
    ) -> Void

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"

    /// The keys the framework itself names for a keyboard backlight. Read out
    /// of its `__TEXT,__cstring` section, so every one of them exists; which of
    /// them the notification block actually delivers is undocumented, so MacTools
    /// asks for all of them and logs what arrives.
    static let notificationKeys = [
        "KeyboardBacklightBrightness",
        "KeyboardBacklightLevel",
        "KeyboardBacklightManualBrightness",
        "KeyboardBacklightABEnabled",
        "KeyboardBacklightSuppressed",
        "KeyboardBacklightIdleDimActive",
    ]

    private(set) var loadFailure: BacklightAvailability.Reason?
    private var client: AnyObject?
    private var observing = false
    /// Loaded once, on the first question anybody asks.
    ///
    /// In practice that is the availability check at launch: the sidebar has to
    /// know whether the Backlight item exists before it can draw itself. The
    /// framework is in the dyld shared cache, so the `dlopen` maps pages that
    /// are already resident and costs microseconds; what this flag really buys
    /// is that a failure is diagnosed and logged exactly once.
    private var loaded = false

    // MARK: - Loading

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard dlopen(KeyboardBacklightClient.frameworkPath, RTLD_LAZY) != nil else {
            loadFailure = .frameworkMissing
            let failure = dlerror().map { String(cString: $0) } ?? "no reason given"
            AppLog.app.error("backlight: CoreBrightness did not load: \(failure, privacy: .public)")
            return
        }
        guard let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            loadFailure = .classMissing
            AppLog.app.error("backlight: KeyboardBrightnessClient is missing")
            return
        }
        client = type.init()
        AppLog.app.notice("backlight: CoreBrightness loaded")
    }

    private func implementation(_ name: String) -> (AnyObject, Selector, IMP)? {
        load()
        guard let client else { return nil }
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(type(of: client), selector) else {
            AppLog.app.error("backlight: \(name, privacy: .public) is missing")
            return nil
        }
        return (client, selector, method_getImplementation(method))
    }

    private func bool(_ name: String, _ keyboard: UInt64) -> Bool {
        guard let (object, selector, imp) = implementation(name) else { return false }
        return unsafeBitCast(imp, to: BoolForID.self)(object, selector, keyboard)
    }

    // MARK: - BacklightClient

    func keyboardIDs() -> [UInt64] {
        guard let (object, selector, imp) = implementation("copyKeyboardBacklightIDs") else {
            return []
        }
        let array = unsafeBitCast(imp, to: CopyIDs.self)(object, selector)
        return (array as? [NSNumber])?.map(\.uint64Value) ?? []
    }

    func isBuiltIn(_ keyboard: UInt64) -> Bool {
        bool("isKeyboardBuiltIn:", keyboard)
    }

    func brightness(_ keyboard: UInt64) -> Double {
        guard let (object, selector, imp) = implementation("brightnessForKeyboard:") else {
            return 0
        }
        let value = unsafeBitCast(imp, to: FloatForID.self)(object, selector, keyboard)
        return BacklightScale.clamp(Double(value))
    }

    func setBrightness(_ value: Double, _ keyboard: UInt64) -> Bool {
        guard let (object, selector, imp) = implementation("setBrightness:forKeyboard:") else {
            return false
        }
        let clamped = Float(BacklightScale.clamp(value))
        return unsafeBitCast(imp, to: SetFloat.self)(object, selector, clamped, keyboard)
    }

    func isAutoEnabled(_ keyboard: UInt64) -> Bool {
        bool("isAutoBrightnessEnabledForKeyboard:", keyboard)
    }

    /// The one call MacTools makes only on an explicit click. The ambient sensor
    /// is the user's setting, not MacTools' to tidy up behind them.
    func setAutoEnabled(_ enabled: Bool, _ keyboard: UInt64) -> Bool {
        guard let (object, selector, imp) = implementation("enableAutoBrightness:forKeyboard:") else {
            return false
        }
        AppLog.app.notice("backlight: auto brightness \(enabled ? "on" : "off", privacy: .public)")
        return unsafeBitCast(imp, to: SetBool.self)(object, selector, enabled, keyboard)
    }

    func isSuppressed(_ keyboard: UInt64) -> Bool {
        bool("isBacklightSuppressedOnKeyboard:", keyboard)
    }

    func isDimmed(_ keyboard: UInt64) -> Bool {
        bool("isBacklightDimmedOnKeyboard:", keyboard)
    }

    /// Asks the framework to push changes instead of being asked for them.
    ///
    /// Which key names it honours is undocumented, so all six go in and the
    /// first arrival is logged. Returning true only means the call was made:
    /// the controller keeps its 1 Hz fallback until a notification really
    /// arrives, because a registration that silently delivers nothing would
    /// otherwise freeze the slider.
    ///
    /// The framework calls the block on a queue of its own, never on the main
    /// thread, so the block hops. `assumeIsolated` here crashed the app on the
    /// first slider move: the write itself is what makes the first
    /// notification arrive.
    func observe(keyboard: UInt64, onChange: @escaping @MainActor @Sendable (String) -> Void) -> Bool {
        guard !observing else { return true }
        guard let (object, selector, imp) = implementation(
            "registerNotificationForKeys:keyboardID:block:"
        ) else { return false }
        let keys = KeyboardBacklightClient.notificationKeys as NSArray
        let block: @convention(block) (NSString, Any?) -> Void = { key, _ in
            let name = key as String
            DispatchQueue.main.async { onChange(name) }
        }
        unsafeBitCast(imp, to: Register.self)(object, selector, keys, keyboard, block)
        observing = true
        return true
    }

    func stopObserving() {
        guard observing, let (object, selector, imp) = implementation(
            "unregisterKeyboardNotificationBlock"
        ) else { return }
        typealias Unregister = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(imp, to: Unregister.self)(object, selector)
        observing = false
    }
}
