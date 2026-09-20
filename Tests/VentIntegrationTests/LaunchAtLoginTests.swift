import ServiceManagement
import XCTest

/// The login item, as far as a test may go.
///
/// `SMAppService.mainApp.register()` needs no password, and that is exactly
/// why no test here calls it: it would add Vent to the Login Items of whoever
/// runs the suite. The mapping from the Service Management status to what the
/// toggle shows is pure, so it is the part that is checked.
final class LaunchAtLoginTests: XCTestCase {
    func testEveryServiceManagementStatusIsMapped() {
        XCTAssertEqual(LaunchAtLoginStatus.of(.enabled), .on)
        XCTAssertEqual(LaunchAtLoginStatus.of(.requiresApproval), .requiresApproval)
    }

    /// Both ways of saying "there is no login item for this app" are off, and
    /// neither is a fault the user has to read about. An app that has never
    /// registered reports `notFound` on macOS 26.2.
    func testAnAppWithNoLoginItemIsSimplyOff() {
        XCTAssertEqual(LaunchAtLoginStatus.of(.notRegistered), .off)
        XCTAssertEqual(LaunchAtLoginStatus.of(.notFound), .off)
        XCTAssertNil(LaunchAtLoginStatus.off.detail)
    }

    /// A registration that waits for approval is what the user asked for, so
    /// the toggle stays on while System Settings has the last word.
    func testPendingApprovalReadsAsOn() {
        XCTAssertTrue(LaunchAtLoginStatus.on.isEnabled)
        XCTAssertTrue(LaunchAtLoginStatus.requiresApproval.isEnabled)
        XCTAssertFalse(LaunchAtLoginStatus.off.isEnabled)
        XCTAssertFalse(LaunchAtLoginStatus.unknown.isEnabled)
    }

    /// Only the states a user cannot act on by themselves carry a sentence,
    /// so the row stays one line in the ordinary case.
    func testOnlyTheStatesThatNeedExplainingCarryDetail() {
        XCTAssertNil(LaunchAtLoginStatus.on.detail)
        XCTAssertNil(LaunchAtLoginStatus.off.detail)
        XCTAssertNotNil(LaunchAtLoginStatus.requiresApproval.detail)
        XCTAssertNotNil(LaunchAtLoginStatus.unknown.detail)
    }
}
