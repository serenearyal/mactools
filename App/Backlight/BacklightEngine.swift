import BacklightKit
import Foundation

/// The rules of the keyboard backlight slider, over a `BacklightClient`.
///
/// Plain, with no timer and no clock of its own: every method that cares about
/// time takes the moment as an argument, so a test can drag a slider across
/// two seconds without waiting two seconds, and a fake client can count the
/// writes that really left.
///
/// `KeyboardBacklightController` is the `@Observable` shell around this; it
/// owns the two timers and nothing else.
@MainActor
final class BacklightEngine {
    /// About ten writes a second. A drag emits a value per frame, and 120 of
    /// them a second through a private framework is both wasteful and visibly
    /// laggy; the last value of each window is the one the eye sees anyway.
    static let writeInterval: TimeInterval = 0.1
    /// How long after a write of ours the hardware is left to catch up before
    /// a poll is allowed to move the slider again. Without it the slider snaps
    /// back to the old value mid-drag.
    static let settleInterval: TimeInterval = 0.8

    private let client: BacklightClient
    private(set) var availability: BacklightAvailability
    private(set) var reading = BacklightReading()
    /// What the slider shows. Ahead of the hardware during a drag.
    private(set) var level: Double = 0
    /// The last value a drag produced that has not been written yet.
    private(set) var pending: Double?
    private(set) var lastWrite = Date.distantPast
    /// Writes that really reached the client. The tests read it; so does the
    /// `--backlight-probe` line.
    private(set) var writeCount = 0
    /// The names of the change notifications that have arrived, if any. Empty
    /// means the push path delivered nothing and polling is carrying the view.
    private(set) var observedKeys: Set<String> = []

    init(client: BacklightClient, forcedUnavailable: Bool = false) {
        self.client = client
        availability = forcedUnavailable
            ? .unavailable(reason: .noKeyboard)
            : .unavailable(reason: .frameworkMissing)
        guard !forcedUnavailable else { return }
        refreshAvailability()
    }

    // MARK: - Availability

    /// The built-in keyboard, or none.
    ///
    /// An external keyboard with a backlight answers `copyKeyboardBacklightIDs`
    /// too, and dimming somebody's Magic Keyboard from a Mac's own settings
    /// panel is not what this switch promises, so only the built-in one counts.
    func refreshAvailability() {
        if let failure = client.loadFailure {
            availability = .unavailable(reason: failure)
            return
        }
        let ids = client.keyboardIDs()
        guard !ids.isEmpty else {
            availability = .unavailable(reason: .noKeyboard)
            return
        }
        let builtIn = ids.filter { client.isBuiltIn($0) }
        guard !builtIn.isEmpty else {
            availability = .unavailable(reason: .notBuiltIn)
            return
        }
        availability = .available(ids: builtIn)
        poll()
    }

    var isAvailable: Bool { availability.isAvailable }

    var keyboard: UInt64? { availability.keyboardIDs.first }

    // MARK: - Reading

    /// One pass over the hardware. Called by the notification block when the
    /// framework pushes, and at 1 Hz while the slider is on screen otherwise.
    ///
    /// A poll that lands inside the settle window updates the flags but leaves
    /// the slider where the user is holding it: the framework reports the
    /// value it has applied, which lags a drag by a frame or two.
    func poll(now: Date = .now) {
        guard let keyboard else { return }
        reading = BacklightReading(
            level: client.brightness(keyboard),
            isAuto: client.isAutoEnabled(keyboard),
            isSuppressed: client.isSuppressed(keyboard),
            isDimmed: client.isDimmed(keyboard)
        )
        guard pending == nil, now.timeIntervalSince(lastWrite) > BacklightEngine.settleInterval
        else { return }
        level = reading.level
    }

    /// Asks the framework to push changes. False means it would not, and the
    /// controller has to poll instead.
    @discardableResult
    func startObserving(onChange: @escaping () -> Void) -> Bool {
        guard let keyboard else { return false }
        return client.observe(keyboard: keyboard) { [weak self] key in
            self?.observedKeys.insert(key)
            AppLog.app.notice("backlight: notification for \(key, privacy: .public)")
            onChange()
        }
    }

    func stopObserving() {
        client.stopObserving()
    }

    // MARK: - Writing

    /// A slider that is moving. Returns true when the value was held back, so
    /// the caller knows a flush has to be scheduled.
    @discardableResult
    func slide(to value: Double, now: Date = .now) -> Bool {
        let clamped = BacklightScale.clamp(value)
        level = clamped
        guard now.timeIntervalSince(lastWrite) >= BacklightEngine.writeInterval else {
            pending = clamped
            return true
        }
        write(clamped, now: now)
        return false
    }

    /// The debounce timer, one window after a value was held back.
    func flush(now: Date = .now) {
        guard let pending else { return }
        write(pending, now: now)
    }

    /// The mouse went up. The value snaps to the same 16-step ladder F5 and F6
    /// walk, so the next key press moves one rung instead of undoing a
    /// fraction the slider left behind.
    func commit(now: Date = .now) {
        let snapped = BacklightScale.level(at: BacklightScale.index(for: level))
        level = snapped
        pending = nil
        write(snapped, now: now)
    }

    private func write(_ value: Double, now: Date) {
        pending = nil
        lastWrite = now
        guard let keyboard else { return }
        writeCount += 1
        guard client.setBrightness(value, keyboard) else {
            AppLog.app.error("backlight: the write of \(value, privacy: .public) was refused")
            return
        }
        reading.level = value
    }

    /// The Auto chip and the "Turn off Auto" button, and nothing else. Vent
    /// never changes the ambient setting on its own.
    func setAuto(_ enabled: Bool) {
        guard let keyboard else { return }
        _ = client.setAutoEnabled(enabled, keyboard)
        reading.isAuto = client.isAutoEnabled(keyboard)
    }

    /// The `--backlight-probe` line, and the `ventctl backlight get` output.
    var summary: String {
        guard let keyboard else {
            return "unavailable: \(availability.reason?.rawValue ?? "unknown")"
        }
        return """
            id \(keyboard), builtIn \(client.isBuiltIn(keyboard)), \
            auto \(reading.isAuto), level \(reading.level), \
            suppressed \(reading.isSuppressed), dimmed \(reading.isDimmed)
            """
    }
}
