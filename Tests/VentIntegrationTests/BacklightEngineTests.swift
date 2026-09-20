import BacklightKit
import Foundation
import Testing

/// The keyboard backlight rules, over a fake keyboard.
///
/// Nothing here touches the real one: the fake counts the writes, so the
/// debounce, the snap on release and the "Vent only changes Auto on a click"
/// rule can all be checked without dimming the keyboard of whoever runs the
/// suite.
@MainActor
@Suite("Backlight engine")
struct BacklightEngineTests {
    final class FakeClient: BacklightClient {
        var loadFailure: BacklightAvailability.Reason?
        var ids: [UInt64] = [95_159_106]
        var builtIn: Set<UInt64> = [95_159_106]
        var level: Double = 0.25
        var auto = false
        var suppressed = false
        var dimmed = false
        var observeSucceeds = false
        private(set) var writes: [Double] = []
        private(set) var autoWrites: [Bool] = []
        private(set) var isObserving = false

        func keyboardIDs() -> [UInt64] { ids }
        func isBuiltIn(_ keyboard: UInt64) -> Bool { builtIn.contains(keyboard) }
        func brightness(_ keyboard: UInt64) -> Double { level }

        func setBrightness(_ value: Double, _ keyboard: UInt64) -> Bool {
            writes.append(value)
            level = value
            return true
        }

        func isAutoEnabled(_ keyboard: UInt64) -> Bool { auto }

        func setAutoEnabled(_ enabled: Bool, _ keyboard: UInt64) -> Bool {
            autoWrites.append(enabled)
            auto = enabled
            return true
        }

        func isSuppressed(_ keyboard: UInt64) -> Bool { suppressed }
        func isDimmed(_ keyboard: UInt64) -> Bool { dimmed }

        func observe(keyboard: UInt64, onChange: @escaping (String) -> Void) -> Bool {
            isObserving = observeSucceeds
            return observeSucceeds
        }

        func stopObserving() { isObserving = false }
    }

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Availability

    @Test("A built-in keyboard that answers is available, and its level is read")
    func available() {
        let client = FakeClient()
        let engine = BacklightEngine(client: client)
        #expect(engine.isAvailable)
        #expect(engine.keyboard == 95_159_106)
        #expect(engine.level == 0.25)
    }

    @Test("Each way the private framework can be missing has its own reason")
    func unavailableReasons() {
        let missing = FakeClient()
        missing.loadFailure = .frameworkMissing
        #expect(BacklightEngine(client: missing).availability.reason == .frameworkMissing)

        let noClass = FakeClient()
        noClass.loadFailure = .classMissing
        #expect(BacklightEngine(client: noClass).availability.reason == .classMissing)

        let noKeyboard = FakeClient()
        noKeyboard.ids = []
        #expect(BacklightEngine(client: noKeyboard).availability.reason == .noKeyboard)

        // An external keyboard with a backlight is not ours to dim.
        let external = FakeClient()
        external.builtIn = []
        #expect(BacklightEngine(client: external).availability.reason == .notBuiltIn)
    }

    @Test("The debug argument makes an available Mac look like one without a light")
    func forcedUnavailable() {
        let engine = BacklightEngine(client: FakeClient(), forcedUnavailable: true)
        #expect(!engine.isAvailable)
        #expect(engine.keyboard == nil)
    }

    @Test("An unavailable engine writes nothing, whatever it is asked")
    func unavailableWritesNothing() {
        let client = FakeClient()
        let engine = BacklightEngine(client: client, forcedUnavailable: true)
        engine.slide(to: 0.9, now: start)
        engine.commit(now: start.addingTimeInterval(1))
        engine.setAuto(false)
        #expect(client.writes.isEmpty)
        #expect(client.autoWrites.isEmpty)
    }

    // MARK: - Writing

    @Test("A drag writes at most about ten times a second, and the last value wins")
    func debounce() {
        let client = FakeClient()
        let engine = BacklightEngine(client: client)
        // The first value of a window goes straight out, so the light follows
        // the hand at once.
        #expect(!engine.slide(to: 0.30, now: start))
        // Sixty more inside the same 100 ms window are all held back.
        for step in 1...60 {
            #expect(engine.slide(to: 0.30 + Double(step) / 1_000, now: start.addingTimeInterval(0.001 * Double(step))))
        }
        #expect(client.writes == [0.30])
        // The slider itself is already at the newest value, even unwritten.
        #expect(engine.level == 0.36)
        engine.flush(now: start.addingTimeInterval(0.1))
        #expect(client.writes.count == 2)
        #expect(client.writes.last == 0.36)
    }

    @Test("A slow drag writes every value, because none of them is held back")
    func slowDrag() {
        let client = FakeClient()
        let engine = BacklightEngine(client: client)
        for step in 0..<5 {
            engine.slide(to: Double(step) / 10, now: start.addingTimeInterval(0.2 * Double(step)))
        }
        #expect(client.writes == [0, 0.1, 0.2, 0.3, 0.4])
    }

    @Test("A flush with nothing pending writes nothing")
    func emptyFlush() {
        let client = FakeClient()
        let engine = BacklightEngine(client: client)
        engine.flush(now: start)
        #expect(client.writes.isEmpty)
    }

    @Test("The release snaps to the same 16 rungs F5 and F6 walk")
    func snapOnRelease() {
        let client = FakeClient()
        let engine = BacklightEngine(client: client)
        engine.slide(to: 0.40, now: start)
        engine.commit(now: start.addingTimeInterval(0.5))
        // 0.40 is 6.4 rungs up, so the nearer one is the sixth: 0.375.
        #expect(engine.level == 6.0 / 16)
        #expect(client.writes.last == 6.0 / 16)
        #expect(client.level == 6.0 / 16)

        // And a value just past the halfway mark goes to the rung above.
        engine.slide(to: 0.42, now: start.addingTimeInterval(1))
        engine.commit(now: start.addingTimeInterval(1.5))
        #expect(engine.level == 7.0 / 16)
    }

    @Test("A value already on a rung is left exactly where it is")
    func snapOnRung() {
        let client = FakeClient()
        let engine = BacklightEngine(client: client)
        engine.slide(to: 0.5, now: start)
        engine.commit(now: start.addingTimeInterval(0.5))
        #expect(engine.level == 0.5)
    }

    @Test("A value out of range lands on the end of the ladder, not past it")
    func clamping() {
        let client = FakeClient()
        let engine = BacklightEngine(client: client)
        engine.slide(to: 4, now: start)
        #expect(engine.level == 1)
        engine.slide(to: -3, now: start.addingTimeInterval(1))
        #expect(engine.level == 0)
        #expect(client.writes == [1, 0])
    }

    // MARK: - Polling

    @Test("A poll follows the hardware once the write has settled")
    func pollAfterSettle() {
        let client = FakeClient()
        let engine = BacklightEngine(client: client)
        engine.slide(to: 0.5, now: start)
        // F6 on the real keyboard, a second later.
        client.level = 0.75
        engine.poll(now: start.addingTimeInterval(BacklightEngine.settleInterval + 0.1))
        #expect(engine.level == 0.75)
    }

    @Test("A poll inside the settle window leaves the slider where the hand is")
    func pollDuringDrag() {
        let client = FakeClient()
        let engine = BacklightEngine(client: client)
        engine.slide(to: 0.5, now: start)
        // The framework still reports the old value for a frame or two; the
        // slider must not snap backwards under the pointer.
        client.level = 0.25
        engine.poll(now: start.addingTimeInterval(0.2))
        #expect(engine.level == 0.5)
    }

    @Test("A poll reads the ambient flags whatever the slider is doing")
    func pollReadsFlags() {
        let client = FakeClient()
        client.suppressed = true
        let engine = BacklightEngine(client: client)
        engine.slide(to: 0.5, now: start)
        engine.poll(now: start.addingTimeInterval(0.1))
        #expect(engine.reading.isSuppressed)
        #expect(engine.reading.stateNote == "Off right now: the room is bright enough.")
    }

    @Test("Suppressed beats dimmed, and neither says anything when both are off")
    func stateNotes() {
        #expect(BacklightReading().stateNote == nil)
        #expect(BacklightReading(isDimmed: true).stateNote?.hasPrefix("Dimmed") == true)
        #expect(
            BacklightReading(isSuppressed: true, isDimmed: true).stateNote?.hasPrefix("Off right now")
                == true
        )
    }

    // MARK: - Auto

    @Test("Auto changes only when it is asked to, never as a side effect")
    func autoIsExplicit() {
        let client = FakeClient()
        client.auto = true
        let engine = BacklightEngine(client: client)
        engine.slide(to: 0.5, now: start)
        engine.commit(now: start.addingTimeInterval(0.2))
        engine.poll(now: start.addingTimeInterval(2))
        #expect(client.autoWrites.isEmpty)
        #expect(engine.reading.isAuto)

        engine.setAuto(false)
        #expect(client.autoWrites == [false])
        #expect(!engine.reading.isAuto)
    }

    // MARK: - Notifications

    @Test("A framework that refuses to push says so, and the caller polls instead")
    func observeRefused() {
        let client = FakeClient()
        let engine = BacklightEngine(client: client)
        #expect(!engine.startObserving {})
        #expect(!client.isObserving)
    }

    @Test("A framework that does push is observed, and the poll is only a belt")
    func observeAccepted() {
        let client = FakeClient()
        client.observeSucceeds = true
        let engine = BacklightEngine(client: client)
        #expect(engine.startObserving {})
        #expect(client.isObserving)
        engine.stopObserving()
        #expect(!client.isObserving)
    }
}
