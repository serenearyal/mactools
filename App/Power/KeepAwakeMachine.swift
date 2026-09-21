import AwakeKit
import Foundation

/// Whether Vent is holding this Mac awake, and until when.
enum KeepAwakeState: Equatable, Sendable {
    case off
    /// Nil for "Indefinitely": the assertion runs until it is released.
    case on(until: Date?)

    var isOn: Bool {
        if case .on = self { return true }
        return false
    }

    var expiry: Date? {
        if case .on(let until) = self { return until }
        return nil
    }
}

/// Everything the user can set about Keep Awake. Persisted, all of it, except
/// the state itself: Vent never comes back awake after a relaunch.
struct KeepAwakeOptions: Equatable, Sendable {
    var duration: KeepAwakeDuration = .indefinite
    var keepDisplayOn = false
    /// "Stay awake with the lid closed": the system-wide `SleepDisabled` flag,
    /// held by the privileged helper for as long as Keep Awake is on.
    ///
    /// Off by default, and this is the one place a default of off is right:
    /// it needs root, it changes how the whole Mac behaves, and a Mac that
    /// cannot sleep with its lid shut overheats in a bag.
    var lidClose = false
    var batteryGuardEnabled = true
    /// Percent. The stepper offers 5 to 50.
    var batteryThreshold = 20

    static let thresholdRange = 5...50
}

/// The Keep Awake state machine: events in, a state and a list of effects out.
///
/// Pure by design. IOKit, the run loop and the clock all live in
/// `KeepAwakeController`; everything that decides whether an assertion exists,
/// when it ends and why it went away is here, where a test can drive it with
/// dates it chooses and a backend that records instead of holding the machine
/// awake.
struct KeepAwakeMachine: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        /// The switch, the popover row or the status item menu.
        case turnOn(now: Date)
        case turnOff
        /// A duration, a display choice or a guard setting changed.
        case optionsChanged(KeepAwakeOptions, now: Date)
        /// The one-shot timer fired: the duration is over.
        case expired
        /// The power source or the thermal state moved.
        case power(PowerStatus, now: Date)
    }

    enum Effect: Equatable, Sendable {
        /// Give up every assertion this app holds. Safe when it holds none.
        case release
        case create(AssertionRequest)
        /// The moment the state must go back to off, or nil to cancel.
        case scheduleExpiry(Date?)
        /// Ask the privileged helper to set or clear the system-wide sleep
        /// setting. Only emitted when the answer changes, so a duration change
        /// does not make an XPC call for nothing.
        case lid(Bool)
    }

    private(set) var state: KeepAwakeState = .off
    /// Nil while the user is in charge. Set when the guard took the assertion
    /// away, and when it refused to give one out.
    private(set) var reason: String?
    /// Only what the guard released may the guard give back: a Keep Awake the
    /// user switched off must not come back when the Mac is plugged in.
    private(set) var releasedByGuard = false
    /// What the machine last asked the helper for. Not what the system says:
    /// the controller reads that back from the helper and shows it.
    private(set) var lidRequested = false
    private(set) var options: KeepAwakeOptions
    private(set) var power = PowerStatus()

    init(options: KeepAwakeOptions = KeepAwakeOptions(), power: PowerStatus = PowerStatus()) {
        self.options = options
        self.power = power
    }

    // MARK: - Events

    /// Every event ends with the lid question, so there is one rule for it and
    /// not one per event: the switch, the timer, the guard, a hotter Mac and
    /// the option itself all reach it the same way.
    mutating func handle(_ event: Event) -> [Effect] {
        route(event) + lidEffects()
    }

    private mutating func route(_ event: Event) -> [Effect] {
        switch event {
        case .turnOn(let now):
            return turnOn(now: now)
        case .turnOff:
            return turnOff()
        case .optionsChanged(let options, let now):
            return optionsChanged(options, now: now)
        case .expired:
            guard state.isOn else { return [] }
            state = .off
            reason = nil
            releasedByGuard = false
            return [.release, .scheduleExpiry(nil)]
        case .power(let reading, let now):
            power = reading
            return applyGuard(now: now)
        }
    }

    private mutating func turnOn(now: Date) -> [Effect] {
        // The guard has the last word on the way in too: switching Keep Awake
        // on at 8 % would only be undone a moment later, and a switch that
        // flips itself back says nothing about why.
        let wasOn = state.isOn
        if let refusal = refusal() {
            state = .off
            reason = refusal
            releasedByGuard = false
            return wasOn ? [.release, .scheduleExpiry(nil)] : []
        }
        reason = nil
        releasedByGuard = false
        return start(now: now, replacing: wasOn)
    }

    private mutating func turnOff() -> [Effect] {
        let wasOn = state.isOn
        state = .off
        reason = nil
        releasedByGuard = false
        return wasOn ? [.release, .scheduleExpiry(nil)] : []
    }

    private mutating func optionsChanged(_ updated: KeepAwakeOptions, now: Date) -> [Effect] {
        let previous = options
        options = updated
        guard state.isOn else {
            // A guard the user just switched off, or a threshold they lowered,
            // can hand back what the guard took.
            return applyGuard(now: now)
        }
        // Nothing the assertion carries changed, so the kernel keeps the one it
        // has: a re-create would reset a countdown the user did not touch.
        guard previous.duration != updated.duration
            || previous.keepDisplayOn != updated.keepDisplayOn
        else { return applyGuard(now: now) }
        return start(now: now, replacing: true)
    }

    /// The lid hold, recomputed after every event and emitted only on a change.
    ///
    /// `LidSleepPolicy` decides; this only remembers what was last asked for,
    /// so a Keep Awake that ends for any reason takes the system-wide flag
    /// with it and a hot Mac gives it back without a rule of its own.
    private mutating func lidEffects() -> [Effect] {
        let wanted = LidSleepPolicy.wantsHold(
            keepAwakeOn: state.isOn,
            lidOptionOn: options.lidClose,
            thermal: power.thermal
        )
        guard wanted != lidRequested else { return [] }
        lidRequested = wanted
        return [.lid(wanted)]
    }

    /// The guard, on every power change and after every option change.
    private mutating func applyGuard(now: Date) -> [Effect] {
        switch BatteryGuard.decide(
            onBattery: guardsBattery && power.onBattery,
            percent: power.percent ?? 100,
            threshold: options.batteryThreshold,
            isOn: state.isOn,
            wasReleasedByGuard: releasedByGuard,
            thermal: power.thermal
        ) {
        case .keep:
            return []
        case .release:
            state = .off
            releasedByGuard = true
            reason = releaseReason()
            return [.release, .scheduleExpiry(nil)]
        case .mayRestore:
            guard releasedByGuard else { return [] }
            releasedByGuard = false
            reason = nil
            return start(now: now, replacing: false)
        }
    }

    /// The charge guard can be switched off; the thermal one cannot. A Mac at
    /// critical thermal state has to be allowed to sleep whatever the settings
    /// say, so `BatteryGuard` sees the real thermal state either way.
    private var guardsBattery: Bool {
        options.batteryGuardEnabled && power.hasBattery
    }

    private mutating func start(now: Date, replacing: Bool) -> [Effect] {
        let expiry = options.duration.seconds.map { now.addingTimeInterval(Double($0)) }
        state = .on(until: expiry)
        let request = AssertionRequest.make(
            duration: options.duration,
            keepDisplayOn: options.keepDisplayOn
        )
        return (replacing ? [.release] : []) + [.create(request), .scheduleExpiry(expiry)]
    }

    // MARK: - Words

    /// Why the guard will not hand one out right now, or nil when it will.
    private func refusal() -> String? {
        if power.thermal == .critical { return "This Mac is too hot to stay awake." }
        guard guardsBattery, power.onBattery, let percent = power.percent,
              percent <= options.batteryThreshold
        else { return nil }
        return "The battery is at \(percent) %, at or below the \(options.batteryThreshold) % guard."
    }

    private func releaseReason() -> String {
        if power.thermal == .critical { return "Turned off: this Mac is too hot." }
        guard let percent = power.percent else { return "Turned off: the battery ran low." }
        return "Turned off: the battery fell to \(percent) %."
    }
}
