import AppKit
import CoreGraphics
import Foundation

/// Where a window was before Vent first moved it.
///
/// Restore is the undo of this whole feature, so the memory has to survive a
/// dozen tiles of a dozen windows and must not grow without bound. 32 entries,
/// least recently used first out: a user works in a handful of windows at a
/// time, and a memory of the window they tiled an hour ago is worth nothing.
///
/// The key is the `CGWindowID` where the private lookup gives one, and the
/// process plus the title otherwise. A pid alone would be wrong: two documents
/// of the same app are two windows with one pid.
@MainActor
final class RestoreMemory {
    enum Key: Hashable {
        case window(CGWindowID)
        case titled(pid_t, String)
    }

    static let capacity = 32

    private var frames: [Key: CGRect] = [:]
    /// Least recently used first. Short enough that an array beats a list.
    private var order: [Key] = []
    private var pids: [Key: pid_t] = [:]
    private var terminationObserver: NSObjectProtocol?

    init(observesTermination: Bool = true) {
        guard observesTermination else { return }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            guard let pid = app?.processIdentifier else { return }
            MainActor.assumeIsolated { self?.purge(pid: pid) }
        }
    }

    // No `deinit`: an observer token is not `Sendable`, and a nonisolated
    // deinit may not touch one under Swift 6. The memory lives as long as the
    // mover does, which is as long as the app does.

    static func key(for target: WindowTarget) -> Key {
        if let id = target.windowID { return .window(id) }
        return .titled(target.pid, target.title)
    }

    /// The first frame wins: pressing left half three times must restore the
    /// window to where it was before the first press, not to the second rung.
    func remember(_ frame: CGRect, for target: WindowTarget) {
        let key = RestoreMemory.key(for: target)
        touch(key)
        pids[key] = target.pid
        guard frames[key] == nil else { return }
        frames[key] = frame
    }

    func frame(for target: WindowTarget) -> CGRect? {
        let key = RestoreMemory.key(for: target)
        guard let frame = frames[key] else { return nil }
        touch(key)
        return frame
    }

    /// Restoring spends the memory: the window is back where it started, so the
    /// next tile from there is a fresh starting point.
    func forget(_ target: WindowTarget) {
        remove(RestoreMemory.key(for: target))
    }

    var count: Int { frames.count }

    /// Every window of an app that has quit. Its pids will be handed out again.
    func purge(pid: pid_t) {
        for (key, owner) in pids where owner == pid {
            remove(key)
        }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > RestoreMemory.capacity, let oldest = order.first {
            remove(oldest)
        }
    }

    private func remove(_ key: Key) {
        frames.removeValue(forKey: key)
        pids.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }
}
