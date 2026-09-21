import XCTest

import SMCKit

/// Read-only checks against the real SMC of the machine that runs the tests.
/// Nothing here writes a key.
final class SMCHardwareTests: XCTestCase {
    private var connection: SMCConnection!

    override func setUpWithError() throws {
        connection = try SMCConnection()
    }

    override func tearDown() {
        connection = nil
    }

    func testTheKeyCatalogMatchesTheReportedKeyCount() throws {
        let start = Date()
        let catalog = try SMCKeyCatalog.load(from: connection)
        let seconds = Date().timeIntervalSince(start)

        XCTAssertGreaterThan(catalog.reportedCount, 100)
        XCTAssertEqual(catalog.count, catalog.reportedCount)
        XCTAssertEqual(catalog.count, try connection.keyCount())
        XCTAssertLessThan(seconds, 2, "enumerating \(catalog.count) keys took \(seconds) s")
        XCTAssertTrue(catalog.contains("FNum"))
    }

    func testFanCountIsPlausible() throws {
        let capabilities = try connection.fanCapabilities()
        XCTAssertTrue((1...4).contains(capabilities.fanCount), "FNum is \(capabilities.fanCount)")
        XCTAssertNotNil(capabilities.modeSuffix, "no F0Md or F0md key")
    }

    func testEveryFanHasAWorkingRange() throws {
        let fans = try connection.readFans()
        XCTAssertFalse(fans.isEmpty)
        for fan in fans {
            XCTAssertLessThan(fan.minimum, fan.maximum, "fan \(fan.index) limits")
            XCTAssertGreaterThan(fan.minimum, 0, "fan \(fan.index) minimum")
            XCTAssertLessThan(fan.maximum, 20_000, "fan \(fan.index) maximum")
            XCTAssertGreaterThanOrEqual(fan.actual, 0, "fan \(fan.index) speed")
            XCTAssertLessThanOrEqual(fan.actual, fan.maximum * 1.1, "fan \(fan.index) speed")
        }
    }

    func testProcessorTemperaturesArePlausible() throws {
        let catalog = try SMCKeyCatalog.load(from: connection)
        let readings = connection.readTemperatures(connection.temperatureKeys(in: catalog))
        let cores = readings.filter { $0.category == .cpuPerformance || $0.category == .cpuEfficiency }

        XCTAssertGreaterThanOrEqual(cores.count, 4, "only \(cores.count) labelled CPU sensors")
        for reading in cores {
            XCTAssertTrue(
                (0...110).contains(reading.celsius),
                "\(reading.key) (\(reading.label)) reads \(reading.celsius) C"
            )
        }
    }

    func testSystemPowerIsReadable() throws {
        let watts = try connection.readDouble("PSTR")
        XCTAssertNotNil(watts)
        XCTAssertTrue((0.1...200).contains(watts ?? 0), "PSTR reads \(String(describing: watts)) W")
    }

    func testAMissingKeyIsReportedAsKeyNotFound() {
        XCTAssertThrowsError(try connection.keyInfo(for: "ZZZZ")) { error in
            XCTAssertEqual(error as? SMCError, .keyNotFound("ZZZZ"))
        }
    }
}
