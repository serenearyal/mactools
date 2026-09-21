import AwakeKit
import Foundation
import Observation

/// Keep Awake: the switch, the countdown, the guard and the assertion itself.
///
/// The decisions are all in `KeepAwakeMachine`, which is pure. This owns the
/// three things a machine cannot: the IOKit assertion, the one-shot timer that
/// ends a duration, and the push notification that tells it the battery moved.
///
/// Nothing polls. The duration ends on its own timer, the battery arrives
/// through `IOPSNotificationCreateRunLoopSource`, and the thermal state through
/// its notification. The only repeating timer in here runs while Keep Awake is
/// on and only to redraw a countdown that changes once a minute.
@MainActor
@Observable
final class KeepAwakeController {
    private(set) var state: KeepAwakeState = .off
    /// Why the guard released it, or refused to hand one out. Nil otherwise.
    private(set) var reason: String?
    /// The power manager said no. Rare, and worth showing when it happens.
    private(set) var failure: String?
    /// What is keeping this Mac awake, Vent included. Only refreshed while the
    /// Keep Awake tab is on screen.
    private(set) var assertions: [AssertionEntry] = []
    /// True when somebody ran `sudo pmset disablesleep 1`. Nil until read.
    private(set) var sleepDisabled: Bool?
    private(set) var power = PowerStatus()

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let backend: KeepAwakeBackend
    @ObservationIgnored private var machine: KeepAwakeMachine
    @ObservationIgnored private var expiryTimer: Timer?
    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var listTimer: Timer?
    @ObservationIgnored private var monitor: PowerSourceMonitor?
    /// Bumped by the countdown timer. The badge reads `remainingText`, which
    /// reads this, so the minute that passes is what invalidates the view.
    private var tick = 0

    /// The assertion list, while its tab is on screen.
    private static let listInterval: TimeInterval = 5

    init(settings: AppSettings, backend: KeepAwakeBackend = IOPMKeepAwakeBackend()) {
        self.settings = settings
        self.backend = backend
        machine = KeepAwakeMachine(options: settings.keepAwakeOptions)
    }

    /// Called once at launch. Reads the battery and subscribes to its pushes.
    func start() {
        let monitor = PowerSourceMonitor { [weak self] reading in
            self?.apply(.power(reading, now: .now))
        }
        self.monitor = monitor
        monitor.start()
        apply(.power(PowerSourceReader.read(), now: .now))
    }

    // MARK: - What the UI reads

    var isOn: Bool { state.isOn }

    var options: KeepAwakeOptions { machine.options }

    /// "42m", "1h 05m", or nil when it is off or runs indefinitely.
    var remainingText: String? {
        _ = tick
        guard let expiry = state.expiry else { return nil }
        return Countdown.text(remainingSeconds: Int(expiry.timeIntervalSinceNow.rounded()))
    }

    /// "Awake 42m", "Awake". The popover header badge and nothing else.
    var badgeText: String? {
        guard state.isOn else { return nil }
        guard let remaining = remainingText else { return "Awake" }
        return "Awake \(remaining)"
    }

    /// The second line of the popover row: the countdown, the guard's reason,
    /// or what the switch would do.
    var detailText: String {
        if state.isOn {
            guard let remaining = remainingText else { return "On, until you turn it off" }
            return "On, \(remaining) left"
        }
        if let reason { return reason }
        if let failure { return failure }
        // Short enough for the popover row, where the duration menu and the
        // switch leave about 180 pt: a second line that wraps makes that row
        // taller than the five beside it.
        return "This Mac sleeps as usual"
    }

    // MARK: - What the UI sets

    func setOn(_ on: Bool) {
        apply(on ? .turnOn(now: .now) : .turnOff)
    }

    func toggle() {
        setOn(!state.isOn)
    }

    func setDuration(_ duration: KeepAwakeDuration) {
        var options = machine.options
        options.duration = duration
        setOptions(options)
    }

    func setKeepDisplayOn(_ on: Bool) {
        var options = machine.options
        options.keepDisplayOn = on
        setOptions(options)
    }

    func setBatteryGuardEnabled(_ on: Bool) {
        var options = machine.options
        options.batteryGuardEnabled = on
        setOptions(options)
    }

    func setBatteryThreshold(_ percent: Int) {
        var options = machine.options
        options.batteryThreshold = percent.clamped(to: KeepAwakeOptions.thresholdRange)
        setOptions(options)
    }

    private func setOptions(_ options: KeepAwakeOptions, persists: Bool = true) {
        guard options != machine.options else { return }
        if persists { settings.keepAwakeOptions = options }
        apply(.optionsChanged(options, now: .now))
    }

    // MARK: - The assertion list

    /// The Keep Awake tab calls this on appear and on disappear. Nothing reads
    /// `IOPMCopyAssertionsByProcess` while nobody is looking at the list.
    func setListVisible(_ visible: Bool) {
        listTimer?.invalidate()
        listTimer = nil
        guard visible else { return }
        refreshList()
        let timer = Timer.scheduledTimer(
            withTimeInterval: KeepAwakeController.listInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshList() }
        }
        timer.tolerance = KeepAwakeController.listInterval / 2
        listTimer = timer
    }

    private func refreshList() {
        assertions = PowerAssertions.all()
        sleepDisabled = PowerAssertions.sleepDisabled()
    }

    // MARK: - The quit path

    /// The last chance to give the assertion back.
    ///
    /// Strictly a courtesy: the kernel drops every assertion a process holds
    /// when it dies, so a `kill -9` leaves nothing behind either. This only
    /// makes the release immediate, and it writes the log line that says so.
    func releaseForTermination() {
        expiryTimer?.invalidate()
        countdownTimer?.invalidate()
        listTimer?.invalidate()
        monitor?.stop()
        backend.release()
    }

    // MARK: - Debug

    /// `--keep-awake-test <seconds>`: on for that many seconds with a one
    /// minute duration, so a run can see the assertion, its timeout and its
    /// release without touching what the user chose. Nothing is persisted.
    func debugTest(seconds: Int) {
        var options = machine.options
        options.duration = .minutes(1)
        setOptions(options, persists: false)
        setOn(true)
        Timer.scheduledTimer(withTimeInterval: Double(max(1, seconds)), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.setOn(false) }
        }
    }

    /// What `--capture` writes about Keep Awake.
    var debugSummary: String {
        let until = state.expiry.map { "\($0.timeIntervalSinceNow.rounded()) s" } ?? "indefinite"
        return "\(state.isOn ? "on (\(until))" : "off"), holding \(backend.isHolding)"
    }

    // MARK: - Effects

    private func apply(_ event: KeepAwakeMachine.Event) {
        let effects = machine.handle(event)
        for effect in effects {
            switch effect {
            case .release:
                backend.release()
            case .create(let request):
                failure = backend.create(request)
            case .scheduleExpiry(let date):
                scheduleExpiry(date)
            }
        }
        if !effects.isEmpty || state != machine.state {
            state = machine.state
        }
        reason = machine.reason
        power = machine.power
        updateCountdown()
    }

    /// One timer, at the moment the duration ends. Not a poll: the kernel is
    /// already releasing the assertion at that second through its own timeout,
    /// and this is only what moves the switch on screen.
    private func scheduleExpiry(_ date: Date?) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let date else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply(.expired) }
        }
        // A second either way on a four-hour hold costs nothing, and it lets
        // the system fold this wakeup into one it was making anyway.
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    /// Redraws the badge when its text is about to change, and not before.
    ///
    /// The text is "42m", so it changes once a minute: the timer aims at the
    /// next minute boundary instead of ticking thirty times for nothing, and
    /// in the last minute, where the text is the fixed "under 1m", it is a
    /// slow heartbeat against clock drift. `SamplingPlan.badgeTick` holds the
    /// rule, and the tests hold the rule to it.
    private func updateCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        tick &+= 1
        guard state.isOn, let expiry = state.expiry else { return }
        let remaining = Int(expiry.timeIntervalSinceNow.rounded())
        let interval = Double(SamplingPlan.badgeTick(remainingSeconds: remaining).components.seconds)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCountdown() }
        }
        timer.tolerance = interval / 5
        countdownTimer = timer
    }
}
