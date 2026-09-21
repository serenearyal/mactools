/// Shared identifiers for the app, the privileged helper and their XPC link.
public enum HelperConstants {
    /// Bundle identifier of the main application.
    public static let appBundleIdentifier = "com.serenearyal.mactools"

    /// Bundle identifier of the debug CLI, the second allowed client.
    public static let mactoolsctlBundleIdentifier = "com.serenearyal.mactools.mactoolsctl"

    /// Bundle identifier of the privileged helper.
    public static let helperBundleIdentifier = "com.serenearyal.mactools.helper"

    /// Mach service the helper vends over XPC.
    public static let machServiceName = "com.serenearyal.mactools.helper"

    /// Name of the LaunchDaemon plist, in `Contents/Library/LaunchDaemons` of
    /// the app bundle and in `/Library/LaunchDaemons` for the legacy install.
    public static let daemonPlistName = "com.serenearyal.mactools.helper.plist"

    /// Where the legacy installer puts the helper binary.
    public static let legacyHelperPath = "/Library/PrivilegedHelperTools/com.serenearyal.mactools.helper"

    /// Where the legacy installer puts the daemon plist.
    public static let legacyPlistPath = "/Library/LaunchDaemons/com.serenearyal.mactools.helper.plist"

    /// The certificate OU of the signing identity, which is the team id.
    public static let teamIdentifier = "M9Q5YCJ5NU"

    /// What this product was called before it was renamed to MacTools on
    /// 2026-09-21, and everything that generation of the helper still occupies
    /// on a Mac that ran it.
    ///
    /// The old daemon is a root job with `RunAtLoad`: nothing about the rename
    /// removes it, and a Mac that keeps it would boot a helper no app talks to
    /// any more. The installer boots it out and deletes these four paths in the
    /// same password prompt as the new install, and the uninstaller removes
    /// both generations. Nothing else refers to these strings, and they are
    /// frozen: they name files on disk that this build did not write.
    public enum Superseded {
        /// The launchd label, which is also the old mach service name.
        public static let machServiceName = "com.serenearyal.vent.helper"

        public static let plistPath = "/Library/LaunchDaemons/com.serenearyal.vent.helper.plist"

        public static let helperPath = "/Library/PrivilegedHelperTools/com.serenearyal.vent.helper"

        /// The marker the old helper wrote when it disabled system sleep. It
        /// survives a reboot, so it has to go with the daemon that owned it.
        public static let sleepMarkerPath = "/var/db/com.serenearyal.vent.helper.sleep-disabled"

        /// Every path the old generation leaves behind, plist first.
        public static let paths = [plistPath, helperPath, sleepMarkerPath]
    }

    // There is no protocol version constant. The build number is the one
    // version both sides already carry: the helper answers `ping` with it, the
    // app compares it with its own and calls nothing until they match, and a
    // second number to bump by hand could only ever disagree with the first.

    /// What the helper demands of a client before it accepts the connection.
    ///
    /// Identifier plus team, never an entitlement: a debug build carries
    /// `get-task-allow` and a release build does not, and a requirement that
    /// looked at entitlements would hold for only one of the two.
    public static let clientCodeSigningRequirement = requirement(
        identifiers: [appBundleIdentifier, mactoolsctlBundleIdentifier]
    )

    /// What a client demands of the helper before it sends anything.
    public static let helperCodeSigningRequirement = requirement(
        identifiers: [helperBundleIdentifier]
    )

    private static func requirement(identifiers: [String]) -> String {
        let clause = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        let subject = identifiers.count > 1 ? "(\(clause))" : clause
        return "\(subject) and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}
