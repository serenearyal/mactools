import Foundation
import XCTest

import HelperProtocol

/// The legacy installer builds a shell script and wraps it in an AppleScript
/// string literal. Both are text, both run as root, and a quoting mistake in
/// either is a broken install at best. These tests lint and compile exactly
/// what the installer would hand to `osascript`, without ever asking for a
/// password.
@MainActor
final class LegacyInstallerScriptTests: XCTestCase {
    /// A directory of its own for each test, removed when the test ends.
    /// `setUp` cannot do it: the overridden method is not main-actor isolated
    /// and this class is.
    private func makeScratch() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "vent-installer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheDaemonPlistIsValidAndNamesTheRightJob() throws {
        let scratch = try makeScratch()
        let text = LegacyHelperInstaller.daemonPlist(programPath: HelperConstants.legacyHelperPath)
        let url = scratch.appending(path: "daemon.plist")
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try run("/usr/bin/plutil", ["-lint", url.path]).status, 0)

        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["Label"] as? String, HelperConstants.machServiceName)
        // A job outside an app bundle needs Program, not BundleProgram.
        XCTAssertEqual(plist["Program"] as? String, HelperConstants.legacyHelperPath)
        XCTAssertNil(plist["BundleProgram"])
        let services = try XCTUnwrap(plist["MachServices"] as? [String: Any])
        XCTAssertEqual(services[HelperConstants.machServiceName] as? Bool, true)
    }

    func testTheInstallScriptCompilesAsAppleScript() throws {
        let command = LegacyHelperInstaller.installScript(
            source: "/Applications/Vent.app/Contents/MacOS/VentHelper"
        )
        XCTAssertTrue(command.contains("launchctl bootstrap system"))
        try assertCompiles(
            LegacyHelperInstaller.appleScript(for: command, reason: "install"),
            in: try makeScratch()
        )
    }

    func testTheUninstallScriptCompilesAndUndoesTheInstall() throws {
        let command = LegacyHelperInstaller.uninstallScript()
        XCTAssertTrue(command.contains("launchctl bootout system/\(HelperConstants.machServiceName)"))
        XCTAssertTrue(command.contains(HelperConstants.legacyPlistPath))
        XCTAssertTrue(command.contains(HelperConstants.legacyHelperPath))
        try assertCompiles(
            LegacyHelperInstaller.appleScript(for: command, reason: "remove"),
            in: try makeScratch()
        )
    }

    /// The end-to-end proof of the escaping: the same plist text, through the
    /// same AppleScript literal and the same shell quoting, has to land on
    /// disk byte for byte. Run without administrator privileges, so no
    /// password sheet appears.
    func testThePlistSurvivesTheAppleScriptAndShellQuoting() throws {
        let target = try makeScratch().appending(path: "written.plist")
        let text = LegacyHelperInstaller.daemonPlist(programPath: HelperConstants.legacyHelperPath)
        let command = "/usr/bin/printf '%s' '\(text)' > '\(target.path)'"
        let script = "do shell script \"\(LegacyHelperInstaller.escapedForAppleScript(command))\""

        let result = try run("/usr/bin/osascript", ["-e", script])
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), text)
        XCTAssertEqual(try run("/usr/bin/plutil", ["-lint", target.path]).status, 0)
    }

    func testAPathThatCouldBreakOutOfTheQuotesIsRefused() {
        XCTAssertThrowsError(try LegacyHelperInstaller.checkQuotable("/tmp/it's here/VentHelper"))
        XCTAssertThrowsError(try LegacyHelperInstaller.checkQuotable("/tmp/a\nb"))
        XCTAssertNoThrow(try LegacyHelperInstaller.checkQuotable("/Applications/Vent 2.app/x"))
    }

    // MARK: - Helpers

    /// `osacompile` parses the script and writes nothing anyone runs, which is
    /// the syntax check the escaping needs.
    private func assertCompiles(_ script: String, in scratch: URL, line: UInt = #line) throws {
        let output = scratch.appending(path: "compiled-\(line).scpt")
        let result = try run("/usr/bin/osacompile", ["-o", output.path, "-e", script])
        XCTAssertEqual(result.status, 0, result.errors, line: line)
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, errors: String) {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
