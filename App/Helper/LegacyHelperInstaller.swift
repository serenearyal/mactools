import Foundation

import HelperProtocol

/// Installs the daemon the old way: copy the helper to
/// `/Library/PrivilegedHelperTools`, write `/Library/LaunchDaemons/<label>.plist`
/// and bootstrap it, all under one admin prompt.
///
/// This exists because `SMAppService.daemon` can refuse a build signed with an
/// Apple Development certificate. The whole privileged part is one shell script
/// run by `osascript ... with administrator privileges`: the user sees a single
/// system password sheet and can read what it is for.
@MainActor
final class LegacyHelperInstaller: HelperInstalling {
    let kind = HelperInstallerKind.legacy

    private let log = AppLog.helper

    func state() -> HelperInstallState {
        let manager = FileManager.default
        let binary = manager.fileExists(atPath: HelperConstants.legacyHelperPath)
        let plist = manager.fileExists(atPath: HelperConstants.legacyPlistPath)
        switch (binary, plist) {
        case (false, false): return .notInstalled
        case (true, true): return .enabled
        default:
            return .stale(
                binary
                    ? "the helper binary is installed without its LaunchDaemon plist"
                    : "the LaunchDaemon plist is installed without its helper binary"
            )
        }
    }

    func install() async throws {
        let source = HelperBundle.bundledHelperURL.path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: source) else {
            throw HelperInstallError.helperMissing(source)
        }
        try Self.checkQuotable(source)
        log.notice("legacy install from \(source, privacy: .public)")
        try await runAsAdministrator(
            Self.installScript(source: source),
            reason: "install the Vent privileged helper"
        )
    }

    func uninstall() async throws {
        try await runAsAdministrator(
            Self.uninstallScript(),
            reason: "remove the Vent privileged helper"
        )
    }

    // MARK: - The scripts

    /// `launchctl bootout` of a job that is not loaded exits non-zero, and that
    /// is fine on both paths: it is how "not installed yet" looks.
    ///
    /// Internal, not private, because the tests lint what it builds.
    static func installScript(source: String) -> String {
        let label = HelperConstants.machServiceName
        let plist = HelperConstants.legacyPlistPath
        let binary = HelperConstants.legacyHelperPath
        return [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/cp -f '\(source)' '\(binary)'",
            "/usr/sbin/chown root:wheel '\(binary)'",
            "/bin/chmod 544 '\(binary)'",
            "/usr/bin/printf '%s' '\(daemonPlist(programPath: binary))' > '\(plist)'",
            "/usr/sbin/chown root:wheel '\(plist)'",
            "/bin/chmod 644 '\(plist)'",
            "{ /bin/launchctl bootout system/\(label) || true; }",
            "/bin/launchctl bootstrap system '\(plist)'",
        ].joined(separator: " && ")
    }

    static func uninstallScript() -> String {
        let label = HelperConstants.machServiceName
        return [
            "{ /bin/launchctl bootout system/\(label) || true; }",
            "/bin/rm -f '\(HelperConstants.legacyPlistPath)'",
            "/bin/rm -f '\(HelperConstants.legacyHelperPath)'",
        ].joined(separator: " && ")
    }

    /// The daemon plist for a job outside an app bundle: `Program`, not
    /// `BundleProgram`. It holds no apostrophe, so the script can quote it.
    static func daemonPlist(programPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>Label</key><string>\(HelperConstants.machServiceName)</string>
        <key>Program</key><string>\(programPath)</string>
        <key>MachServices</key>
        <dict><key>\(HelperConstants.machServiceName)</key><true/></dict>
        </dict>
        </plist>
        """
    }

    // MARK: - Running it

    /// Every path in the script is single quoted, so a path that holds a quote
    /// or a newline would break out of it. Refuse instead of building it.
    static func checkQuotable(_ path: String) throws {
        let forbidden = CharacterSet(charactersIn: "'\"\\\n\r")
        guard path.rangeOfCharacter(from: forbidden) == nil else {
            throw HelperInstallError.unsafePath(path)
        }
    }

    /// The whole privileged part, as the one AppleScript the user is asked to
    /// authorise.
    static func appleScript(for command: String, reason: String) -> String {
        """
        do shell script "\(escapedForAppleScript(command))" \
        with prompt "Vent needs your password to \(reason)." \
        with administrator privileges
        """
    }

    private func runAsAdministrator(_ command: String, reason: String) async throws {
        guard let message = await Self.runOSAScript(Self.appleScript(for: command, reason: reason))
        else { return }
        // -128 is "user cancelled" and needs no alert.
        if message.contains("-128") || message.localizedCaseInsensitiveContains("cancel") {
            throw HelperInstallError.cancelled
        }
        log.error("legacy install failed: \(message, privacy: .public)")
        throw HelperInstallError.commandFailed(message)
    }

    /// The command is one AppleScript string literal, so a backslash, a quote
    /// or a line break in it has to be escaped once more. An AppleScript
    /// literal cannot hold a raw newline, and the plist text has plenty.
    static func escapedForAppleScript(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Nil on success, the message osascript printed on failure. The prompt
    /// blocks until the user answers it, so this never runs on the main actor.
    private static func runOSAScript(_ source: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/osascript")
            // No shell: the script is one argv element, whatever it holds.
            process.arguments = ["-e", source]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = Pipe()
            do {
                try process.run()
            } catch {
                return "cannot run osascript: \(error.localizedDescription)"
            }
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "osascript exited with \(process.terminationStatus)" : text
        }.value
    }
}
