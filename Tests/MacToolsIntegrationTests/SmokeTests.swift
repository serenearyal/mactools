import XCTest

import FanControl
import HelperProtocol
import ScanKit
import SMCKit
import SysMetrics

final class SmokeTests: XCTestCase {
    func testMacToolsCoreModulesAreLinked() {
        XCTAssertEqual(SMC.serviceName, "AppleSMC")
        XCTAssertEqual(Fans.thermalInterlockCelsius, 100)
        XCTAssertEqual(Metrics.defaultSampleInterval, 1)
        XCTAssertEqual(Scan.dataVolumePath, "/System/Volumes/Data")
        XCTAssertEqual(HelperConstants.appBundleIdentifier, "com.serenearyal.mactools")
    }
}
