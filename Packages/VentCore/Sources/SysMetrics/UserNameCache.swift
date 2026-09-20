import Darwin
import Foundation
import Synchronization

/// uid to login name, remembered.
///
/// `getpwuid` can reach opendirectory, and the process table asks for the same
/// handful of uids 580 times every refresh. The answers are kept for the life
/// of the process; an account that is renamed while the app runs is not worth
/// a cache invalidation.
///
/// Concurrency: the lock is held across the lookup on purpose. `getpwuid`
/// returns a pointer into storage it owns, so two threads in it at once may
/// read each other's result.
public final class UserNameCache: Sendable {
    public typealias Lookup = @Sendable (uid_t) -> String?

    public static let shared = UserNameCache()

    private let lookup: Lookup
    private let names: Mutex<[uid_t: String]>

    public init(lookup: @escaping Lookup = UserNameCache.passwordDatabase) {
        self.lookup = lookup
        names = Mutex([:])
    }

    /// The login name, or the number itself when the account has no name.
    public func name(for uid: uid_t) -> String {
        names.withLock { cache in
            if let cached = cache[uid] { return cached }
            let name = lookup(uid) ?? String(uid)
            cache[uid] = name
            return name
        }
    }

    /// How many uids the cache holds. The one thing a test can look at to see
    /// that a second question did not ask the system again.
    public var count: Int {
        names.withLock { $0.count }
    }

    public static let passwordDatabase: Lookup = { uid in
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return nil }
        let text = String(cString: name)
        return text.isEmpty ? nil : text
    }
}
