import Foundation
import Synchronization
import Testing

/// The lid hold, driven against a helper that never was.
///
/// Two things are proved here, and they are the two that a Mac in a bag
/// depends on. The first is order: only the newest wanted value is sent, and a
/// slow answer to an older one never decides what this Mac is doing. The
/// second is reconciliation: a clear the helper refused is asked for again,
/// and again, until the read-back says the hold is gone.
///
/// Nothing sleeps: the retry wait is injected and returns at once, and "slow"
/// is a gate the test opens by hand.
@Suite("Lid sleep reconciler")
struct LidSleepReconcilerTests {
    /// The flag, in memory, with the helper's own rules about it: Vent's
    /// helper never takes over, and never clears, a flag somebody else set.
    actor FakePort: LidSleepPort {
        private(set) var writes: [Bool] = []
        private(set) var reads = 0
        private(set) var flagSet = false
        private(set) var isOurs = false

        /// The next reads fail, the way a missing helper does.
        private var failReads = 0
        /// The next writes are refused, with a reason.
        private var refuseWrites = 0
        /// While this is closed, a write waits for `open()`.
        private var gateClosed = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var watchers: [CheckedContinuation<Void, Never>] = []

        static let refusal = "the helper refused"

        // MARK: What the test sets up

        /// Somebody ran `pmset disablesleep 1`.
        func setForeignFlag() {
            flagSet = true
            isOurs = false
        }

        func failNextReads(_ count: Int) { failReads = count }

        func refuseNextWrites(_ count: Int) { refuseWrites = count }

        func closeGate() { gateClosed = true }

        func open() {
            gateClosed = false
            for continuation in waiting { continuation.resume() }
            waiting = []
        }

        /// Returns once at least `count` writes have started.
        func waitForWrite(count: Int) async {
            while writes.count < count {
                await withCheckedContinuation { watchers.append($0) }
            }
        }

        // MARK: The port

        func write(_ on: Bool) async -> String? {
            writes.append(on)
            for continuation in watchers { continuation.resume() }
            watchers = []
            if gateClosed {
                await withCheckedContinuation { waiting.append($0) }
            }
            if refuseWrites > 0 {
                refuseWrites -= 1
                return FakePort.refusal
            }
            // The helper's own rule: a flag it did not set is not its to move.
            if flagSet, !isOurs { return "somebody else set this flag" }
            flagSet = on
            isOurs = on
            return nil
        }

        func readBack() async -> LidSleepFacts? {
            reads += 1
            if failReads > 0 {
                failReads -= 1
                return nil
            }
            return LidSleepFacts(flagSet: flagSet, isOurs: isOurs)
        }
    }

    /// Every outcome the reconciler published, and every retry wait it asked
    /// for. The waits are answered at once, so the suite takes no time at all.
    final class Recorder: Sendable {
        private let outcomes = Mutex<[LidSleepOutcome]>([])
        private let waits = Mutex<[Duration]>([])

        var all: [LidSleepOutcome] { outcomes.withLock { $0 } }
        var last: LidSleepOutcome? { outcomes.withLock { $0.last } }
        var delays: [Duration] { waits.withLock { $0 } }

        func record(_ outcome: LidSleepOutcome) {
            outcomes.withLock { $0.append(outcome) }
        }

        func sleep(_ delay: Duration) {
            waits.withLock { $0.append(delay) }
        }
    }

    private func make() -> (LidSleepReconciler, FakePort, Recorder) {
        let port = FakePort()
        let recorder = Recorder()
        let reconciler = LidSleepReconciler(port: port) { delay in
            recorder.sleep(delay)
        }
        reconciler.observe { outcome in recorder.record(outcome) }
        return (reconciler, port, recorder)
    }

    // MARK: - Order

    @Test("Two requests in the same turn send only the newest")
    func offThenOnFast() async {
        let (reconciler, port, _) = make()
        reconciler.request(false)
        reconciler.request(true)
        await reconciler.settled()

        #expect(await port.flagSet)
        #expect(await port.isOurs)
        // The clear was never sent: there was nothing of ours to clear, and
        // the request was stale before the first pass reached the helper.
        #expect(await port.writes == [true])
    }

    @Test("A clear asked for during a slow hold wins, and lands last")
    func onThenOffWithASlowFirstCall() async {
        let (reconciler, port, recorder) = make()
        await port.closeGate()
        reconciler.request(true)
        await port.waitForWrite(count: 1)

        // The switch goes off while the helper is still answering the first
        // call. This is the sequence that used to leave the flag set.
        reconciler.request(false)
        await port.open()
        await reconciler.settled()

        #expect(await port.writes == [true, false])
        #expect(await port.flagSet == false)
        #expect(await port.isOurs == false)
        #expect(recorder.last?.retrying == false)
    }

    @Test("Quitting while a request is in flight still ends with the flag clear")
    func quitDuringARequest() async {
        let (reconciler, port, _) = make()
        await port.closeGate()
        reconciler.request(true)
        await port.waitForWrite(count: 1)

        let quit = Task { await reconciler.clearForQuit() }
        await port.open()
        await quit.value

        #expect(await port.writes == [true, false])
        #expect(await port.flagSet == false)
    }

    @Test("Quitting clears a hold nobody asked it to clear")
    func quitClearsWhateverIsHeld() async {
        let (reconciler, port, _) = make()
        reconciler.request(true)
        await reconciler.settled()

        // No `request(false)` first: the quit path asks the flag itself, not
        // the switch, because a clear that was refused leaves the switch
        // believing the hold is already gone.
        await reconciler.clearForQuit()
        #expect(await port.writes == [true, false])
        #expect(await port.flagSet == false)
    }

    @Test("Quitting does not wait for an observer that waits for the quitting thread")
    func quitDoesNotWaitForTheObserver() async {
        let (reconciler, port, _) = make()
        reconciler.request(true)
        await reconciler.settled()

        // The real observer hops to the main actor, and the quit path blocks
        // the main thread: an observer that never returns stands in for it.
        reconciler.observe { _ in
            try? await Task.sleep(for: .seconds(3600))
        }
        await reconciler.clearForQuit()
        #expect(await port.flagSet == false)
    }

    // MARK: - Reconciliation

    @Test("A refused hold is retried up the ladder until it takes")
    func failureThenRetry() async {
        let (reconciler, port, recorder) = make()
        await port.refuseNextWrites(2)
        reconciler.request(true)
        await reconciler.settled()

        #expect(await port.writes == [true, true, true])
        #expect(await port.flagSet)
        #expect(recorder.delays == [.seconds(1), .seconds(2)])
        #expect(recorder.last?.retrying == false)
        #expect(recorder.all.first?.refusal == FakePort.refusal)
    }

    @Test("A refused clear is chased until the read-back says the hold is gone")
    func refusedClearIsChased() async {
        let (reconciler, port, recorder) = make()
        reconciler.request(true)
        await reconciler.settled()

        await port.refuseNextWrites(3)
        reconciler.request(false)
        await reconciler.settled()

        #expect(await port.writes == [true, false, false, false, false])
        #expect(await port.flagSet == false)
        // The ladder started again from the bottom for the new intent.
        #expect(recorder.delays == [.seconds(1), .seconds(2), .seconds(4)])
        // And while it was chasing, it said so: this is what the UI shows
        // instead of "this Mac sleeps as usual".
        let chasing = recorder.all.filter { !$0.wanted && $0.retrying }
        #expect(chasing.count == 3)
        #expect(recorder.last?.retrying == false)
    }

    @Test("Nothing is written while the wanted state and the flag agree")
    func agreementWritesNothing() async {
        let (reconciler, port, _) = make()
        reconciler.request(true)
        await reconciler.settled()
        let writes = await port.writes

        reconciler.verify()
        await reconciler.settled()
        reconciler.request(true)
        await reconciler.settled()

        #expect(await port.writes == writes)
        #expect(await port.reads > 2)
    }

    @Test("A flag somebody else set is asked for once and then left alone")
    func foreignFlagIsNotChased() async {
        let (reconciler, port, recorder) = make()
        await port.setForeignFlag()
        reconciler.request(true)
        await reconciler.settled()

        #expect(await port.writes == [true])
        #expect(await port.flagSet, "the flag stays: it is not Vent's to move")
        #expect(await port.isOurs == false)
        #expect(recorder.last?.retrying == false)
        #expect(recorder.last?.refusal != nil)
        #expect(recorder.delays.isEmpty)
    }

    @Test("A clear still goes out when the read-back itself fails")
    func readFailureFallsBackOnWhatWasKnown() async {
        let (reconciler, port, _) = make()
        reconciler.request(true)
        await reconciler.settled()

        await port.failNextReads(1)
        reconciler.request(false)
        await reconciler.settled()

        #expect(await port.writes == [true, false])
        #expect(await port.flagSet == false)
    }

    @Test("With nothing ever held, a clear calls the helper for nothing")
    func nothingToClear() async {
        let (reconciler, port, recorder) = make()
        await port.failNextReads(2)
        reconciler.request(false)
        await reconciler.settled()

        #expect(await port.writes.isEmpty)
        #expect(recorder.last?.retrying == false)
    }

    // MARK: - The rules themselves

    @Test("The write only goes out when the two states differ")
    func needsWriteRules() {
        let ours = LidSleepFacts(flagSet: true, isOurs: true)
        let theirs = LidSleepFacts(flagSet: true, isOurs: false)
        let clear = LidSleepFacts()

        #expect(LidSleepReconciler.needsWrite(target: true, facts: clear))
        #expect(!LidSleepReconciler.needsWrite(target: true, facts: ours))
        #expect(LidSleepReconciler.needsWrite(target: false, facts: ours))
        #expect(!LidSleepReconciler.needsWrite(target: false, facts: clear))
        #expect(!LidSleepReconciler.needsWrite(target: false, facts: theirs))
        // Nothing has ever been read back: only a hold that is wanted is worth
        // a blind write.
        #expect(LidSleepReconciler.needsWrite(target: true, facts: nil))
        #expect(!LidSleepReconciler.needsWrite(target: false, facts: nil))
    }

    @Test("A hold of ours that nobody wants is the one thing retried for ever")
    func retryRules() {
        let ours = LidSleepFacts(flagSet: true, isOurs: true)
        let theirs = LidSleepFacts(flagSet: true, isOurs: false)
        let clear = LidSleepFacts()

        #expect(LidSleepReconciler.retries(target: false, facts: ours))
        #expect(!LidSleepReconciler.retries(target: false, facts: clear))
        #expect(!LidSleepReconciler.retries(target: false, facts: theirs))
        #expect(LidSleepReconciler.retries(target: true, facts: clear))
        #expect(!LidSleepReconciler.retries(target: true, facts: ours))
        #expect(!LidSleepReconciler.retries(target: true, facts: theirs))
        #expect(LidSleepReconciler.retries(target: true, facts: nil))
        #expect(!LidSleepReconciler.retries(target: false, facts: nil))
    }

    @Test("The ladder is 1, 2, 4, 8 seconds and then every thirty")
    func ladder() {
        #expect(LidSleepRetry.delay(attempt: 1) == .seconds(1))
        #expect(LidSleepRetry.delay(attempt: 2) == .seconds(2))
        #expect(LidSleepRetry.delay(attempt: 3) == .seconds(4))
        #expect(LidSleepRetry.delay(attempt: 4) == .seconds(8))
        #expect(LidSleepRetry.delay(attempt: 5) == .seconds(30))
        #expect(LidSleepRetry.delay(attempt: 99) == .seconds(30))
    }
}
