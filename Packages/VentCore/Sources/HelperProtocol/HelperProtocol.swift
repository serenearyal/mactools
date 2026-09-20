/// Shared identifiers for the app, the privileged helper and their XPC link.
public enum HelperConstants {
    /// Bundle identifier of the main application.
    public static let appBundleIdentifier = "com.serenearyal.vent"

    /// Bundle identifier of the debug CLI, the second allowed client.
    public static let ventctlBundleIdentifier = "com.serenearyal.vent.ventctl"

    /// Bundle identifier of the privileged helper.
    public static let helperBundleIdentifier = "com.serenearyal.vent.helper"

    /// Mach service the helper vends over XPC.
    public static let machServiceName = "com.serenearyal.vent.helper"

    /// Name of the LaunchDaemon plist, in `Contents/Library/LaunchDaemons` of
    /// the app bundle and in `/Library/LaunchDaemons` for the legacy install.
    public static let daemonPlistName = "com.serenearyal.vent.helper.plist"

    /// Where the legacy installer puts the helper binary.
    public static let legacyHelperPath = "/Library/PrivilegedHelperTools/com.serenearyal.vent.helper"

    /// Where the legacy installer puts the daemon plist.
    public static let legacyPlistPath = "/Library/LaunchDaemons/com.serenearyal.vent.helper.plist"

    /// The certificate OU of the signing identity, which is the team id.
    public static let teamIdentifier = "M9Q5YCJ5NU"

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
        identifiers: [appBundleIdentifier, ventctlBundleIdentifier]
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
