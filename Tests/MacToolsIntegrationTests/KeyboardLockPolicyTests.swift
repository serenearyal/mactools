import CoreGraphics
import XCTest

/// The rules of the keyboard lock, without a tap.
///
/// The source file under test is compiled into this bundle (see
/// `project.yml`), so the app and the test share one copy of the logic that
/// decides when the keyboard comes back.
final class KeyboardLockPolicyTests: XCTestCase {
    // MARK: - Event mask

    func testMaskHoldsExactlyTheFourTypes() {
        let expected: [UInt32] = [
            CGEventType.keyDown.rawValue,
            CGEventType.keyUp.rawValue,
            CGEventType.flagsChanged.rawValue,
            LockEventMask.systemDefinedType,
        ]
        for bit in expected {
            XCTAssertNotEqual(LockEventMask.value & (CGEventMask(1) << bit), 0, "bit \(bit) missing")
        }
        XCTAssertEqual(LockEventMask.value.nonzeroBitCount, expected.count)
    }

    func testSystemDefinedTypeIsNXSysDefined() {
        // IOKit/hidsystem/IOLLEvent.h: #define NX_SYSDEFINED 14
        XCTAssertEqual(LockEventMask.systemDefinedType, 14)
    }

    func testOnlyAuxControlButtonsAreSwallowed() {
        // 8 is NX_SUBTYPE_AUX_CONTROL_BUTTONS, the media keys.
        XCTAssertTrue(LockEventMask.swallowsSystemDefined(subtype: 8))
        // 7 is NX_SUBTYPE_AUX_MOUSE_BUTTONS: the mouse is the unlock path.
        XCTAssertFalse(LockEventMask.swallowsSystemDefined(subtype: 7))
        for subtype in [0, 1, 2, 3, 6, 9, 11] {
            XCTAssertFalse(LockEventMask.swallowsSystemDefined(subtype: subtype))
        }
    }

    // MARK: - Escape chord

    func testThreeEscapesInsideTheWindowUnlock() {
        var chord = UnlockChord()
        XCTAssertFalse(chord.registerEscape(at: 10.0))
        XCTAssertFalse(chord.registerEscape(at: 10.5))
        XCTAssertTrue(chord.registerEscape(at: 11.2))
    }

    func testTheThirdEscapeAloneDoesNotUnlock() {
        var chord = UnlockChord()
        XCTAssertFalse(chord.registerEscape(at: 10.0))
        XCTAssertFalse(chord.registerEscape(at: 10.5))
        XCTAssertFalse(chord.registerEscape(at: 20.0))
    }

    /// The window slides: a press that falls out of it drops, and the two
    /// that follow it plus one more still unlock.
    func testWindowSlides() {
        var chord = UnlockChord()
        XCTAssertFalse(chord.registerEscape(at: 0))
        XCTAssertFalse(chord.registerEscape(at: 5.0))
        XCTAssertFalse(chord.registerEscape(at: 5.5))
        XCTAssertTrue(chord.registerEscape(at: 6.0))
    }

    func testExactlyTwoSecondsApartStillCounts() {
        var chord = UnlockChord()
        XCTAssertFalse(chord.registerEscape(at: 0))
        XCTAssertFalse(chord.registerEscape(at: 1))
        XCTAssertTrue(chord.registerEscape(at: 2))
    }

    /// Documented behaviour: only Escape reaches the chord at all. The tap
    /// never offers another key code, so a cloth pressing the rest of the
    /// keyboard can neither complete nor reset it.
    func testChordResetsAfterItFires() {
        var chord = UnlockChord()
        _ = chord.registerEscape(at: 0)
        _ = chord.registerEscape(at: 0.2)
        XCTAssertTrue(chord.registerEscape(at: 0.4))
        XCTAssertFalse(chord.registerEscape(at: 0.6))
        XCTAssertFalse(chord.registerEscape(at: 0.8))
        XCTAssertTrue(chord.registerEscape(at: 1.0))
    }

    func testEscapeKeyCode() {
        // kVK_Escape from Carbon's Events.h.
        XCTAssertEqual(UnlockChord.escapeKeyCode, 53)
    }

    // MARK: - Hold to unlock

    func testShortPressDoesNotUnlock() {
        XCTAssertFalse(HoldToUnlock.isComplete(elapsed: 0))
        XCTAssertFalse(HoldToUnlock.isComplete(elapsed: 0.2))
        XCTAssertFalse(HoldToUnlock.isComplete(elapsed: 1.49))
        XCTAssertTrue(HoldToUnlock.isComplete(elapsed: 1.5))
    }

    func testHoldProgressIsClamped() {
        XCTAssertEqual(HoldToUnlock.progress(elapsed: -1), 0)
        XCTAssertEqual(HoldToUnlock.progress(elapsed: 0.75), 0.5, accuracy: 0.0001)
        XCTAssertEqual(HoldToUnlock.progress(elapsed: 99), 1)
    }

    // MARK: - Timeout

    func testTimeoutClamping() {
        XCTAssertEqual(LockTimeout.clamp(0), 15)
        XCTAssertEqual(LockTimeout.clamp(-30), 15)
        XCTAssertEqual(LockTimeout.clamp(15), 15)
        XCTAssertEqual(LockTimeout.clamp(60), 60)
        XCTAssertEqual(LockTimeout.clamp(300), 300)
        XCTAssertEqual(LockTimeout.clamp(3_600), 300)
    }

    func testDebugTimeoutNeverExceedsTenSeconds() {
        XCTAssertEqual(LockTimeout.clampDebug(5), 5)
        XCTAssertEqual(LockTimeout.clampDebug(10), 10)
        XCTAssertEqual(LockTimeout.clampDebug(11), 10)
        XCTAssertEqual(LockTimeout.clampDebug(600), 10)
        XCTAssertEqual(LockTimeout.clampDebug(0), 1)
    }

    func testEveryOfferedTimeoutIsInsideTheRange() {
        for seconds in LockTimeout.choices {
            XCTAssertEqual(LockTimeout.clamp(seconds), seconds)
        }
        XCTAssertTrue(LockTimeout.choices.contains(LockTimeout.default))
    }

    func testTimeoutTitles() {
        XCTAssertEqual(LockTimeout.title(15), "15 s")
        XCTAssertEqual(LockTimeout.title(60), "1 min")
        XCTAssertEqual(LockTimeout.title(300), "5 min")
        XCTAssertEqual(LockTimeout.title(90), "1 min 30 s")
    }

    // MARK: - Permissions and recovery

    func testCanLockNeedsBothGrantsAndNoSecureInput() {
        XCTAssertFalse(LockPermissions().canLock)
        XCTAssertFalse(LockPermissions(accessibility: true).canLock)
        XCTAssertTrue(LockPermissions(accessibility: true, inputMonitoring: true).canLock)
        XCTAssertFalse(
            LockPermissions(
                accessibility: true,
                inputMonitoring: true,
                secureInputEnabled: true
            ).canLock
        )
    }

    /// The bug this covers: a lock refused for a missing permission stayed
    /// `.failed` for the rest of the session, even after the user granted it.
    func testAGrantedPermissionEndsAFailedState() {
        let granted = LockPermissions(accessibility: true, inputMonitoring: true)
        XCTAssertTrue(LockRecovery.clearsFailure(isFailed: true, permissions: granted))
    }

    func testAFailedStateSurvivesWhileAPermissionIsMissing() {
        XCTAssertFalse(
            LockRecovery.clearsFailure(
                isFailed: true,
                permissions: LockPermissions(accessibility: true)
            )
        )
        XCTAssertFalse(
            LockRecovery.clearsFailure(
                isFailed: true,
                permissions: LockPermissions(
                    accessibility: true,
                    inputMonitoring: true,
                    secureInputEnabled: true
                )
            )
        )
    }

    func testAStateThatDidNotFailIsNeverTouched() {
        XCTAssertFalse(
            LockRecovery.clearsFailure(
                isFailed: false,
                permissions: LockPermissions(accessibility: true, inputMonitoring: true)
            )
        )
    }
}
