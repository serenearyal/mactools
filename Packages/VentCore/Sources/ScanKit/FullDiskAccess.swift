import Darwin
import Foundation

/// Whether this process may read the files TCC protects.
///
/// No API answers the question. The reliable probe is to open a file that
/// only Full Disk Access unlocks, the TCC database itself: `EPERM` means the
/// grant is missing. The scan still works without it, it just cannot see
/// Mail, Messages, Photos and the other protected folders, and those show up
/// as unreadable entries.
public enum FullDiskAccess {
    /// Opens System Settings straight on the Full Disk Access list.
    public static let settingsURLString =
        "x-apple-systempreferences:com.apple.preference.security?Privacy_AllFiles"

    public static var userDatabasePath: String {
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
    }

    public static let systemDatabasePath = "/Library/Application Support/com.apple.TCC/TCC.db"

    public static func isGranted() -> Bool {
        for path in [userDatabasePath, systemDatabasePath] {
            switch probe(path) {
            case .granted: return true
            case .denied: return false
            case .absent: continue
            }
        }
        // Neither database is there, so nothing on this machine can tell a
        // grant from a refusal. Claim access rather than nag.
        return true
    }

    enum Probe: Equatable {
        case granted
        case denied
        case absent
    }

    static func probe(_ path: String) -> Probe {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor < 0 else {
            close(descriptor)
            return .granted
        }
        return errno == EPERM || errno == EACCES ? .denied : .absent
    }
}
