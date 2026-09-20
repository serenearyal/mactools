/// Shared identifiers for the app, the privileged helper and their XPC link.
///
/// The XPC protocol and its payloads arrive in a later batch.
public enum HelperConstants {
    /// Bundle identifier of the main application.
    public static let appBundleIdentifier = "com.serenearyal.vent"

    /// Bundle identifier of the privileged helper.
    public static let helperBundleIdentifier = "com.serenearyal.vent.helper"

    /// Mach service the helper vends over XPC.
    public static let machServiceName = "com.serenearyal.vent.helper"

    /// Wire version of the helper protocol. Bumped on any breaking change.
    public static let protocolVersion = 1
}
