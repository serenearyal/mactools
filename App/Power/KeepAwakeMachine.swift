import AwakeKit
import Foundation
import Synchronization

/// Whether MacTools is holding this Mac awake, and until when.
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
/// the state itself: MacTools never comes back awake after a relaunch.
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

// MARK: - The lid hold, reconciled

/// The system-wide flag as the helper last reported it back.
///
/// Read, never remembered: what the machine asked for says nothing about what
/// this Mac is doing, and a clear that was refused leaves the two apart.
struct LidSleepFacts: Equatable, Sendable {
    /// `SleepDisabled` is set, by anybody.
    var flagSet = false
    /// And the helper's own marker says MacTools set it, so MacTools may clear it.
    var isOurs = false
}

/// What the reconciler needs from the world: one write and one read-back.
///
/// Neither call is typed to XPC and neither throws, so the sequencing and the
/// retries can be driven by a test with no helper, no root, and no Mac that
/// stops sleeping for the length of the suite.
protocol LidSleepPort: Sendable {
    /// Ask for the flag. Nil when the helper did it, the reason when it refused.
    func write(_ on: Bool) async -> String?
    /// Read it back. Nil when the read itself failed.
    func readBack() async -> LidSleepFacts?
}

/// One pass of the reconciler: what it wanted, what it did, what it found.
struct LidSleepOutcome: Equatable, Sendable {
    /// The state this pass was trying to reach.
    var wanted: Bool
    /// True when the helper was actually asked to change something.
    var wrote: Bool
    /// The helper's refusal, nil when it obeyed or was not asked.
    var refusal: String?
    /// The read-back, nil when the read itself failed.
    var facts: LidSleepFacts?
    /// True while the wanted state and the read-back still differ and another
    /// attempt is scheduled. The UI says so: nothing is ever silently stuck.
    var retrying: Bool
}

/// How long to wait before going back for a flag that would not move.
///
/// 1 s, 2 s, 4 s, 8 s, then every 30 s for as long as the two states differ.
/// Each wait is one tolerant sleep and not a poll: when the wanted state and
/// the read-back agree, nothing at all is scheduled.
enum LidSleepRetry {
    static let ladder: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
    /// What the ladder settles into. Slow enough to cost nothing, often enough
    /// that a helper which comes back is used within half a minute.
    static let floor = Duration.seconds(30)

    /// The wait after the given attempt, counting from one.
    static func delay(attempt: Int) -> Duration {
        guard attempt > 1 else { return ladder[0] }
        guard attempt <= ladder.count else { return floor }
        return ladder[attempt - 1]
    }
}

/// The one path every request for the lid flag takes.
///
/// Two jobs, and they are the same job. The first is order: a slow `set(false)`
/// and a fast `set(true)` that each had their own task could land in either
/// order and leave a Mac that cannot sleep with its lid shut. Here one worker
/// runs at a time, it always reads the newest wanted value, and a result that
/// comes back for an older value never decides that the work is done.
///
/// The second is reconciliation. A request is not a result: the helper can
/// refuse, it can be missing, and the flag can be changed by somebody else. So
/// every pass reads the flag back and compares it with what is wanted, and
/// while they differ the ladder above goes back for it. This is what keeps
/// "Keep Awake off" from leaving `SleepDisabled` set, which is a Mac that
/// cooks in a closed bag.
///
/// A final class over a `Mutex` rather than an actor: the wanted value has to
/// be written synchronously, at the instant the switch moves, so that two
/// requests in the same run loop turn cannot reach the worker out of order.
final class LidSleepReconciler: Sendable {
    /// Called after every pass, on whatever thread the worker runs on. The
    /// controller hops to the main actor itself, and must not wait for the
    /// hop: see `clearForQuit`.
    typealias Observer = @Sendable (LidSleepOutcome) async -> Void

    private struct State {
        var wanted = false
        /// The last read-back that arrived. What a failed read falls back to.
        var known: LidSleepFacts?
        /// True while something has asked for a pass that has not started yet.
        var dirty = false
        var worker: Task<Void, Never>?
        var waiter: Task<Void, Never>?
        var observer: Observer?
    }

    private let port: any LidSleepPort
    private let sleep: @Sendable (Duration) async -> Void
    private let state = Mutex(State())

    init(
        port: any LidSleepPort,
        sleep: @escaping @Sendable (Duration) async -> Void = LidSleepReconciler.wait
    ) {
        self.port = port
        self.sleep = sleep
    }

    /// One tolerant one-shot sleep. A retry is not a deadline, and a wakeup the
    /// system can fold into one it was making anyway costs the battery nothing.
    static func wait(_ delay: Duration) async {
        try? await Task.sleep(for: delay, tolerance: delay / 5)
    }

    func observe(_ observer: @escaping Observer) {
        state.withLock { $0.observer = observer }
    }

    /// The wanted state moved. Synchronous on purpose: the last caller in this
    /// run loop turn wins, whichever task reaches the helper first.
    func request(_ on: Bool) {
        kick { $0.wanted = on }
    }

    /// Read the flag back now and act only if it differs from what is wanted.
    ///
    /// The tab's five-second list, the popover appearing, and every power and
    /// thermal push the controller already receives all come through here.
    func verify() {
        kick { _ in }
    }

    /// The quit path: want it clear, and wait for the chain to reach that.
    ///
    /// The caller bounds the wait; this is the part that must not be raced.
    /// Asking the helper from a second task while a request was in flight is
    /// exactly how a `set(true)` lands after a `set(false)`.
    ///
    /// The observer goes first. The quit path blocks the main thread while it
    /// waits for this, and an observer that waited for the main actor would
    /// make the worker wait for the thread that was waiting for the worker:
    /// every quit sat out its whole timeout before the helper's last-client
    /// rule cleared the flag instead. Detaching it stops a later pass from
    /// calling it; one pass may already be inside it, which is why the app's
    /// observer hops to the main actor without waiting for the hop.
    func clearForQuit() async {
        kick {
            $0.observer = nil
            $0.wanted = false
        }
        await settled()
    }

    /// Waits for the current chain to end. The quit path and the tests use it.
    func settled() async {
        guard let worker = state.withLock({ $0.worker }) else { return }
        await worker.value
    }

    /// What the last read-back said, for a test and for a log line.
    var lastKnown: LidSleepFacts? { state.withLock { $0.known } }

    // MARK: - The rules

    /// Whether the flag has to be written to reach `target`.
    ///
    /// Nil facts mean nothing has ever been read back: only a hold that is
    /// wanted is worth a blind write, because a clear with nothing to clear
    /// would call the helper for nothing at every launch.
    static func needsWrite(target: Bool, facts: LidSleepFacts?) -> Bool {
        guard let facts else { return target }
        return target ? !facts.isOurs : facts.isOurs
    }

    /// Whether the two states still differ, so another attempt is owed.
    ///
    /// A flag somebody else set is not a difference to retry: the helper will
    /// not take over a hold it did not make, and the UI says who holds it. A
    /// hold of ours that is still there when nobody wants it is the one case
    /// that retries for as long as it lasts.
    static func retries(target: Bool, facts: LidSleepFacts?) -> Bool {
        guard let facts else { return target }
        return target ? !facts.isOurs && !facts.flagSet : facts.isOurs
    }

    // MARK: - The worker

    private func kick(_ change: (inout State) -> Void) {
        state.withLock { state in
            change(&state)
            state.dirty = true
            // A retry that is waiting wakes up instead of sitting out its
            // ladder step: the user just moved the switch.
            state.waiter?.cancel()
            guard state.worker == nil else { return }
            // Made under the lock so the handle exists the moment this returns,
            // which is what lets the quit path wait for this very chain. A task
            // never starts inline, so nothing runs while the lock is held.
            state.worker = Task { await self.run() }
        }
    }

    private func run() async {
        var attempt = 0
        var last: Bool?
        while true {
            let target = state.withLock { state -> Bool in
                state.dirty = false
                return state.wanted
            }
            // A fresh intent starts at the bottom of the ladder; the same
            // failure twice climbs it.
            if target != last {
                attempt = 0
                last = target
            }

            let outcome = await pass(target: target)
            if let observer = state.withLock({ $0.observer }) { await observer(outcome) }

            // Whatever arrived while the helper was answering wins: an older
            // result never decides that this is finished.
            if state.withLock({ $0.dirty || $0.wanted != target }) { continue }

            if outcome.retrying {
                attempt += 1
                await wait(LidSleepRetry.delay(attempt: attempt))
                continue
            }
            let done = state.withLock { state -> Bool in
                guard !state.dirty else { return false }
                state.worker = nil
                return true
            }
            if done { return }
        }
    }

    private func pass(target: Bool) async -> LidSleepOutcome {
        let before = await port.readBack()
        let knownBefore = record(before)
        guard LidSleepReconciler.needsWrite(target: target, facts: knownBefore) else {
            return LidSleepOutcome(
                wanted: target,
                wrote: false,
                refusal: nil,
                facts: before,
                retrying: LidSleepReconciler.retries(target: target, facts: knownBefore)
            )
        }
        let refusal = await port.write(target)
        let after = await port.readBack()
        return LidSleepOutcome(
            wanted: target,
            wrote: true,
            refusal: refusal,
            facts: after,
            // The read-back has the last word, and when it fails the last one
            // that worked does: a hold this app knows it took is not forgotten
            // because the helper went missing for a moment.
            retrying: LidSleepReconciler.retries(target: target, facts: record(after))
        )
    }

    /// Keeps the newest read-back and answers with the best knowledge there is.
    private func record(_ facts: LidSleepFacts?) -> LidSleepFacts? {
        state.withLock { state in
            if let facts { state.known = facts }
            return state.known
        }
    }

    private func wait(_ delay: Duration) async {
        let waiter = state.withLock { state -> Task<Void, Never> in
            let waiter = Task { await self.sleep(delay) }
            state.waiter = waiter
            return waiter
        }
        await waiter.value
        state.withLock { if $0.waiter == waiter { $0.waiter = nil } }
    }
}
