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
        let url = URL.temporaryDirectory.appending(path: "mactools-installer-tests-\(UUID().uuidString)")
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
            source: "/Applications/MacTools.app/Contents/MacOS/MacToolsHelper"
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

    // MARK: - The helper of the name before the rename

    /// The old daemon is a root job with `RunAtLoad`, so only an install of
    /// this app is ever in a position to remove it, and it has to happen in the
    /// prompt the user is already answering.
    func testTheInstallClearsTheDaemonOfTheOldName() throws {
        let command = LegacyHelperInstaller.installScript(
            source: "/Applications/MacTools.app/Contents/MacOS/MacToolsHelper"
        )
        let bootout = "launchctl bootout system/\(HelperConstants.Superseded.machServiceName)"
        XCTAssertTrue(command.contains(bootout))
        for path in HelperConstants.Superseded.paths {
            XCTAssertTrue(command.contains("/bin/rm -f '\(path)'"), path)
        }
        // The old job first: its SIGTERM is what clears the system sleep
        // setting it may be holding, and the marker below is removed after.
        let cleanup = try XCTUnwrap(command.range(of: bootout))
        let install = try XCTUnwrap(command.range(of: "launchctl bootstrap system"))
        XCTAssertTrue(cleanup.upperBound < install.lowerBound)
        let marker = try XCTUnwrap(command.range(of: HelperConstants.Superseded.sleepMarkerPath))
        XCTAssertTrue(cleanup.upperBound < marker.lowerBound)
        try assertCompiles(
            LegacyHelperInstaller.appleScript(for: command, reason: "install"),
            in: try makeScratch()
        )
    }

    /// An uninstall leaves nothing of either generation behind.
    func testTheUninstallRemovesBothGenerations() throws {
        let command = LegacyHelperInstaller.uninstallScript()
        XCTAssertTrue(
            command.contains("launchctl bootout system/\(HelperConstants.Superseded.machServiceName)")
        )
        for path in HelperConstants.Superseded.paths {
            XCTAssertTrue(command.contains("/bin/rm -f '\(path)'"), path)
        }
    }

    /// The cleanup and the write of the daemon plist, in one script, through
    /// the same AppleScript literal and the same shell quoting the installer
    /// uses - with one leftover file present and the rest missing, which is
    /// what every Mac that never ran the old name looks like.
    ///
    /// The real paths are swapped for paths in a scratch directory, because a
    /// test may not delete a file of `/Library`, and the `launchctl` line is
    /// left out because only root may boot a system job out. What is proved is
    /// the quoting and the "each one only if it is there, and a failure stops
    /// nothing" shape, which is where this kind of script goes wrong.
    func testTheCleanupQuotesItsPathsAndSurvivesFilesThatAreNotThere() throws {
        let scratch = try makeScratch()
        let manager = FileManager.default
        let redirect = { (path: String) in
            scratch.appending(path: URL(filePath: path).lastPathComponent).path
        }
        let present = redirect(HelperConstants.Superseded.plistPath)
        try Data().write(to: URL(filePath: present))

        var cleanup = LegacyHelperInstaller.supersededCleanup()
            .filter { !$0.contains("launchctl") }
            .joined(separator: " && ")
        for path in HelperConstants.Superseded.paths {
            cleanup = cleanup.replacingOccurrences(of: "'\(path)'", with: "'\(redirect(path))'")
        }
        XCTAssertFalse(cleanup.contains("/Library/"), "a real path survived the redirect")

        let target = scratch.appending(path: "written.plist")
        let text = LegacyHelperInstaller.daemonPlist(programPath: HelperConstants.legacyHelperPath)
        let command = cleanup + " && /usr/bin/printf '%s' '\(text)' > '\(target.path)'"
        let script = "do shell script \"\(LegacyHelperInstaller.escapedForAppleScript(command))\""

        let result = try run("/usr/bin/osascript", ["-e", script])
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertFalse(manager.fileExists(atPath: present), "the leftover file is still there")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), text)
        XCTAssertEqual(try run("/usr/bin/plutil", ["-lint", target.path]).status, 0)
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
        XCTAssertThrowsError(try LegacyHelperInstaller.checkQuotable("/tmp/it's here/MacToolsHelper"))
        XCTAssertThrowsError(try LegacyHelperInstaller.checkQuotable("/tmp/a\nb"))
        XCTAssertNoThrow(try LegacyHelperInstaller.checkQuotable("/Applications/MacTools 2.app/x"))
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
