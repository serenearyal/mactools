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
    private(set) var power = PowerStatus()

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let backend: KeepAwakeBackend
    @ObservationIgnored private let lid: any LidSleepBackend
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
        self.lid = lid
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
        // A flag left set by a Vent that was killed is the helper's to clear,
        // and it does that when the connection dies and again at its own
        // start. This only makes sure the first thing the user sees is the
        // truth about their Mac.
        refreshSleepSetting()
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
        if state.isOn {
            guard let remaining = remainingText else { return blocking.title }
            return "\(blocking.title), \(remaining) left"
        }
        if let reason { return reason }
        if let failure { return failure }
        return blocking.title
    }

    /// The reinstall prompt, when the installed helper is too old to know what
    /// the lid option is. Nil when there is nothing to reinstall.
    var lidNeedsReinstall: Bool { HelperGate.shared.blockedReason != nil }

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
        refreshSleepSetting()
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
        blocking = AwakeBlocking(
            idleSleepHeld: held.idleSystemSleep,
            displaySleepHeld: held.idleDisplaySleep,
            lidSleepBlocked: flag,
            lidSleepIsOurs: flag && lidIsOurs
        )
    }

    /// Asks the helper who owns the flag, then redraws. Nothing calls this on
    /// a timer: it runs at launch, after every lid request and whenever the
    /// tab's five-second list finds a flag whose owner is not known yet.
    private func refreshSleepSetting() {
        let flag = PowerAssertions.sleepDisabled() ?? false
        guard flag || machine.lidRequested else {
            lidIsOurs = false
            verify()
            return
        }
        Task { [lid] in
            let report = try? await lid.report()
            await MainActor.run {
                self.lidIsOurs = report?.setByVent ?? false
                self.verify()
            }
        }
    }

    /// One request to the helper, and a read-back of what it did.
    private func requestLid(_ on: Bool) {
        Task { [lid] in
            var refusal: String?
            do {
                try await lid.set(on)
            } catch {
                refusal = error.localizedDescription
            }
            let report = try? await lid.report()
            await MainActor.run {
                // A failed clear is worth a log line and nothing on screen:
                // the helper clears the flag by itself when this app goes
                // away, so there is nothing for the user to do about it.
                if on {
                    self.lidFailure = refusal
                } else if let refusal {
                    AppLog.app.error("the lid hold could not be cleared: \(refusal, privacy: .public)")
                }
                self.lidIsOurs = report?.setByVent ?? false
                self.verify()
                AppLog.app.notice(
                    """
                    lid hold \(on ? "requested" : "released", privacy: .public): \
                    flag \(self.blocking.lidSleepBlocked, privacy: .public), \
                    ours \(self.blocking.lidSleepIsOurs, privacy: .public)\
                    \(refusal.map { ", \($0)" } ?? "", privacy: .public)
                    """
                )
            }
        }
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
        guard machine.lidRequested else { return }
        let lid = self.lid
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            try? await lid.set(false)
            semaphore.signal()
        }
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
            + "lid \(blocking.lidSleepBlocked) (ours \(blocking.lidSleepIsOurs))"
    }

    /// The Keep Awake tab and the popover row ask for one read-back when they
    /// appear, so a panel that opens shows the truth without waiting for the
    /// five-second timer.
    func verifyNow() {
        verify()
        refreshSleepSetting()
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
