import AwakeKit
import Foundation
import Observation

import HelperProtocol

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
    /// True when this Mac has `SleepDisabled` set, by anybody. Nil until read.
    private(set) var sleepDisabled: Bool?
    /// What this Mac is refusing to do right now, read back from the power
    /// manager rather than taken from the switch. Everything the UI says about
    /// "on" comes from here.
    private(set) var blocking = AwakeBlocking()
    /// Why the lid hold is not on, when the user asked for it: no helper, an
    /// old helper, or a flag somebody else set. Nil while all is well.
    private(set) var lidFailure: String?
    /// True while Vent wants the system-wide flag clear and the read-back still
    /// says the hold is Vent's. The retry is running, and the UI has to say so:
    /// a Mac that cannot sleep with its lid shut cooks in a bag, and "sleeps as
    /// usual" would be a lie at the worst possible moment.
    private(set) var lidClearPending = false
    /// The reinstall prompt, when the installed helper is too old to know what
    /// the lid option is.
    ///
    /// Mirrored from `HelperGate`, which is a plain shared value with no
    /// observation: a view that read the gate itself would never redraw when
    /// the helper is installed again. Refreshed on every read-back.
    private(set) var lidNeedsReinstall = false
    private(set) var power = PowerStatus()

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let backend: KeepAwakeBackend
    /// Every lid request and every lid read-back goes through this one, in
    /// order, with the retry that a refused clear needs.
    @ObservationIgnored private let reconciler: LidSleepReconciler
    @ObservationIgnored private var machine: KeepAwakeMachine
    @ObservationIgnored private var expiryTimer: Timer?
    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var listTimer: Timer?
    @ObservationIgnored private var monitor: PowerSourceMonitor?
    /// The helper's last word on who set the flag.
    @ObservationIgnored private var lidIsOurs = false
    /// Bumped by the countdown timer. The badge reads `remainingText`, which
    /// reads this, so the minute that passes is what invalidates the view.
    private var tick = 0

    /// The assertion list, while its tab is on screen.
    private static let listInterval: TimeInterval = 5
    /// How long the quit path waits for the helper to confirm the clear.
    private static let terminationWait: DispatchTimeInterval = .seconds(1)

    init(
        settings: AppSettings,
        backend: KeepAwakeBackend = IOPMKeepAwakeBackend(),
        lid: any LidSleepBackend = HelperLidSleepBackend()
    ) {
        self.settings = settings
        self.backend = backend
        reconciler = LidSleepReconciler(port: lid)
        machine = KeepAwakeMachine(options: settings.keepAwakeOptions)
    }

    /// Called once at launch. Reads the battery and subscribes to its pushes.
    func start() {
        // The worker runs on the cooperative pool, so this hops rather than
        // assuming anything about the thread it is called back on.
        reconciler.observe { [weak self] outcome in
            await MainActor.run { self?.absorb(outcome) }
        }
        let monitor = PowerSourceMonitor { [weak self] reading in
            self?.apply(.power(reading, now: .now))
        }
        self.monitor = monitor
        monitor.start()
        apply(.power(PowerSourceReader.read(), now: .now))
        // A flag left set by a Vent that was killed is the helper's to clear,
        // and it does that when the connection dies and again at its own
        // start. This only makes sure the first thing the user sees is the
        // truth about their Mac.
        reconcile()
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

    /// The second line of the popover row and the tab's status line: what is
    /// blocked right now, in plain words, from the read-back.
    ///
    /// The countdown joins it rather than replacing it, so the row never says
    /// "On" while the kernel holds nothing. Short enough for the popover row,
    /// where the duration menu and the switch leave about 180 pt: a second
    /// line that wraps makes that row taller than the five beside it.
    var detailText: String {
        // First, ahead of the countdown and ahead of the guard's own words: a
        // hold that would not come off is the one thing here that can hurt.
        if lidClearPending { return KeepAwakeController.clearRetryText }
        if state.isOn {
            guard let remaining = remainingText else { return blocking.title }
            return "\(blocking.title), \(remaining) left"
        }
        if let reason { return reason }
        if let failure { return failure }
        return blocking.title
    }

    /// What the tab and the popover row say while a clear is being retried.
    static let clearRetryText = "Lid-close sleep is still blocked - retrying"

    /// True when the flag is set and it is not Vent's. Nothing destructive is
    /// ever offered against it.
    var lidSetBySomebodyElse: Bool { blocking.lidSleepBlocked && !blocking.lidSleepIsOurs }

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

    /// "Stay awake with the lid closed". Remembered, like the other options;
    /// the flag itself is never restored at launch, because Keep Awake is not.
    func setLidClose(_ on: Bool) {
        var options = machine.options
        options.lidClose = on
        // A refusal belongs to the request that caused it.
        lidFailure = nil
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
        // One read of who owns the flag when the tab appears, whoever owns it.
        reconcile()
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
        verify()
        // The tab is the one surface that watches the flag over time, so its
        // five seconds are also when a helper that came back is noticed. Only
        // while Vent has something at stake: a flag that is somebody else's is
        // read once, when the tab appears, and not every five seconds after.
        guard hasLidStake else { return }
        reconcile()
    }

    /// True while there is a hold Vent wants or a hold Vent took. Nothing is
    /// asked of the helper outside it.
    private var hasLidStake: Bool {
        machine.lidRequested || lidIsOurs || lidClearPending
    }

    // MARK: - The read-back

    /// What the power manager says this process is holding, and what the
    /// system sleep setting is.
    ///
    /// The local half needs no helper and no root: `IOPMCopyAssertionsByProcess`
    /// for our own pid, and `IOPMCopySystemPowerSettings` for the flag. Who
    /// owns the flag is the helper's answer, and it is only asked for when the
    /// flag is set or Vent is trying to hold it.
    private func verify() {
        let held = PowerAssertions.heldBy()
        let flag = PowerAssertions.sleepDisabled() ?? false
        sleepDisabled = flag
        // A flag that is gone is nobody's, and there is nothing left to retry.
        if !flag {
            lidIsOurs = false
            lidClearPending = false
        }
        // The gate is a shared value with no observation of its own, so the
        // hint under the switch only moves when this mirror does.
        let blocked = HelperGate.shared.blockedReason != nil
        if lidNeedsReinstall, !blocked, machine.lidRequested {
            // The helper was just reinstalled with the switch still on.
            reconciler.request(true)
        }
        lidNeedsReinstall = blocked
        blocking = AwakeBlocking(
            idleSleepHeld: held.idleSystemSleep,
            displaySleepHeld: held.idleDisplaySleep,
            lidSleepBlocked: flag,
            lidSleepIsOurs: flag && lidIsOurs
        )
    }

    /// Compares what the machine wants with what the helper says is true, and
    /// closes the gap. Nothing polls: this runs at launch, after every lid
    /// request, on every power and thermal push, and while the tab's list is
    /// on screen.
    ///
    /// The local flag read is what keeps the helper out of it: with the flag
    /// clear and nothing wanted there is no hold to own, so no XPC call is
    /// made at all.
    private func reconcile() {
        let flag = PowerAssertions.sleepDisabled() ?? false
        guard flag || hasLidStake else {
            lidIsOurs = false
            verify()
            return
        }
        reconciler.verify()
    }

    /// The machine asked for the flag. The reconciler owns the order and the
    /// retry; this only records the intent, and it records it synchronously so
    /// that two requests in the same turn cannot reach the helper out of order.
    ///
    /// A hold is not asked of a helper the gate has already refused: the
    /// answer is known, and chasing it would wake the app every 30 s for as
    /// long as the switch is on. A clear is always sent.
    private func requestLid(_ on: Bool) {
        reconciler.request(on && HelperGate.shared.blockedReason == nil)
    }

    /// What came back from a pass over the flag. The one place the UI learns
    /// whether the hold is on, off, refused, or still being chased.
    private func absorb(_ outcome: LidSleepOutcome) {
        if let facts = outcome.facts { lidIsOurs = facts.isOurs }
        // Off and still held: the user has to be told, because this is the
        // state where a closed Mac gets hot in a bag.
        lidClearPending = !outcome.wanted && outcome.retrying
        if outcome.wanted {
            lidFailure = outcome.refusal
        } else if let refusal = outcome.refusal {
            AppLog.app.error(
                "the lid hold could not be cleared: \(refusal, privacy: .public); going back for it"
            )
        }
        verify()
        guard outcome.wrote || outcome.retrying else { return }
        AppLog.app.notice(
            """
            lid hold \(outcome.wanted ? "requested" : "released", privacy: .public): \
            flag \(self.blocking.lidSleepBlocked, privacy: .public), \
            ours \(self.blocking.lidSleepIsOurs, privacy: .public), \
            retrying \(outcome.retrying, privacy: .public)\
            \(outcome.refusal.map { ", \($0)" } ?? "", privacy: .public)
            """
        )
    }

    // MARK: - The quit path

    /// The last chance to give the assertion and the system sleep setting back.
    ///
    /// The assertion is strictly a courtesy: the kernel drops every assertion
    /// a process holds when it dies, so a `kill -9` leaves nothing behind
    /// either. The sleep setting is not the kernel's to drop, so it is cleared
    /// here with a bounded wait - and the helper clears it again by itself
    /// when this connection dies, which is what covers the `kill -9`.
    func releaseForTermination() {
        expiryTimer?.invalidate()
        countdownTimer?.invalidate()
        listTimer?.invalidate()
        monitor?.stop()
        backend.release()
        // Not `machine.lidRequested`: a clear that was refused leaves the
        // machine believing the flag is gone while this Mac still cannot sleep
        // with its lid shut. The flag itself, and the helper's marker on it,
        // are the only things worth trusting here - and the reconciler asks
        // the helper before it writes, so a flag that is somebody else's costs
        // one read and nothing more.
        let flagSet = PowerAssertions.sleepDisabled() ?? false
        guard flagSet || machine.lidRequested || lidIsOurs else { return }
        let reconciler = self.reconciler
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await reconciler.clearForQuit()
            semaphore.signal()
        }
        // A bounded wait on the main thread, the same shape as the fan quit
        // path `FanStore.restoreAllAutoOnTermination`: `HelperConnection` is an
        // actor off the main actor, `applicationWillTerminate` cannot await,
        // and a quit that hangs on a dead helper is worse than a flag the
        // dying connection clears anyway.
        if semaphore.wait(timeout: .now() + KeepAwakeController.terminationWait) == .timedOut {
            AppLog.app.error(
                "the helper did not confirm the lid hold was cleared; the connection dropping clears it"
            )
        }
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

    /// What `--capture` writes about Keep Awake. The read-back, not the
    /// switch: this line is what a run proves the assertion with.
    var debugSummary: String {
        let until = state.expiry.map { "\($0.timeIntervalSinceNow.rounded()) s" } ?? "indefinite"
        return "\(state.isOn ? "on (\(until))" : "off"), holding \(backend.isHolding), "
            + "verified idle \(blocking.idleSleepHeld), display \(blocking.displaySleepHeld), "
            + "lid \(blocking.lidSleepBlocked) (ours \(blocking.lidSleepIsOurs)), "
            + "clear pending \(lidClearPending)"
    }

    /// The Keep Awake tab and the popover row ask for one read-back when they
    /// appear, so a panel that opens shows the truth without waiting for the
    /// five-second timer.
    func verifyNow() {
        verify()
        reconcile()
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
            case .lid(let on):
                requestLid(on)
            }
        }
        if !effects.isEmpty || state != machine.state {
            state = machine.state
        }
        reason = machine.reason
        power = machine.power
        // Straight after the create or the release, so the switch on screen
        // and the kernel agree from the first frame.
        verify()
        // And the helper's half of it. Every power and thermal push arrives
        // here, so a hold that would not come off is chased on each of them as
        // well as on its own ladder. Only when Vent has a stake in the flag:
        // a flag that belongs to `pmset` must not wake the helper once a
        // minute for an answer nobody acts on.
        if hasLidStake { reconcile() }
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
