import Foundation
import Synchronization

/// The system-wide `SleepDisabled` flag: what it means, who owns it, and the
/// rules that keep Vent from ever clearing one it did not set.
///
/// This is what `sudo pmset disablesleep 1` writes. It is not an assertion: it
/// is a system power setting that stops the Mac sleeping at all, including on a
/// closed lid and on the Apple menu's Sleep, and it survives a reboot. Only
/// root can move it, so the privileged helper owns it and the app asks.
///
/// Why this lives in `HelperProtocol` rather than in `AwakeKit`: both ends of
/// the XPC call have to agree on the ownership rules, and `HelperProtocol` is
/// the one module the app, the helper, `ventctl` and the tests all link. The
/// decisions are values and pure functions here; the two IOKit calls are in
/// the helper, behind `SystemSleepSwitch`, so no test can write the flag of
/// the machine it runs on.

// MARK: - What the flag says

/// Who put the flag where it is.
public enum SleepDisabledOwner: String, Codable, Sendable, Equatable {
    /// The flag is clear: this Mac sleeps as usual.
    case nobody
    /// Vent's helper set it, and Vent will clear it again.
    case vent
    /// Somebody else set it, `pmset` by hand being the usual way. Vent leaves
    /// it strictly alone: it did not set it, so it is not Vent's to undo.
    case somebodyElse
}

/// The flag and the helper's own marker, as one value. This is what crosses
/// the XPC link and what the UI reads.
public struct SleepDisabledReport: Codable, Sendable, Equatable {
    /// The `SleepDisabled` system power setting itself.
    public let isSet: Bool
    /// True when the helper's marker says this run, or a previous run of it,
    /// is the one that set the flag.
    public let setByVent: Bool

    public init(isSet: Bool, setByVent: Bool) {
        self.isSet = isSet
        self.setByVent = setByVent
    }

    public static let clear = SleepDisabledReport(isSet: false, setByVent: false)

    public var owner: SleepDisabledOwner {
        guard isSet else { return .nobody }
        return setByVent ? .vent : .somebodyElse
    }

    /// The one thing the user cares about: a closed lid does not sleep this
    /// Mac while this is true, whoever set it.
    public var blocksLidSleep: Bool { isSet }
}

// MARK: - The rules

/// When the helper may write the flag, and when it must keep its hands off.
///
/// Pure, and deliberately separate from the IOKit calls: "never clear a flag
/// we did not set" is a safety rule, and a safety rule that can only be tested
/// by disabling sleep on the machine running the test is not tested at all.
public enum SleepDisabledPolicy {
    public enum SetDecision: Sendable, Equatable {
        /// Write the flag and take ownership of it.
        case write
        /// Already set, and already ours. Nothing to do.
        case alreadyOurs
        /// Already set by somebody else. Refuse, and say so.
        case foreign
    }

    public enum ClearDecision: Sendable, Equatable {
        /// Clear the flag and drop the marker.
        case clear
        /// Nothing is set. Drop a marker if one is left over.
        case nothingToClear
        /// Set, but not by us. Leave it exactly as it is.
        case notOurs
    }

    public static func set(isSet: Bool, marked: Bool) -> SetDecision {
        guard isSet else { return .write }
        return marked ? .alreadyOurs : .foreign
    }

    /// The same decision for every way the flag comes back off: the switch,
    /// the timer, the battery guard, a hot Mac, the app quitting, the last
    /// client disconnecting, a signal, and the marker found at helper start.
    public static func clear(isSet: Bool, marked: Bool) -> ClearDecision {
        guard marked else { return isSet ? .notOurs : .nothingToClear }
        // Marked but clear means somebody else already undid it; the marker is
        // stale and the governor drops it.
        return isSet ? .clear : .nothingToClear
    }

    /// What the helper answers, and the UI shows, when the flag is somebody
    /// else's. Nothing destructive is ever offered against it.
    public static let foreignMessage =
        "this Mac already has sleep disabled system-wide (pmset disablesleep 1); "
            + "Vent did not set that and will not change it"
}

// MARK: - The two system calls, behind a protocol

/// The `SleepDisabled` system power setting, read and written.
///
/// A protocol for one reason: the real one needs root and changes how this Mac
/// behaves, so the only implementation a test may ever see is the in-memory
/// one below. The real one is built in the helper target alone.
public protocol SystemSleepSwitch: Sendable {
    func read() throws -> Bool
    func write(_ disabled: Bool) throws
}

/// The helper's memory of "I set it", kept across a restart of the helper and
/// across a reboot, because the flag itself is.
public protocol SleepDisabledMarker: Sendable {
    var isMarked: Bool { get }
    func mark()
    func unmark()
}

/// The fake power settings of the tests, in the spirit of `InMemoryFanHardware`.
public final class InMemorySleepSwitch: SystemSleepSwitch {
    private let state: Mutex<(value: Bool, writes: Int, failure: String?)>

    public init(disabled: Bool = false, failure: String? = nil) {
        state = Mutex((value: disabled, writes: 0, failure: failure))
    }

    /// What the flag is now, without counting as a read by the governor.
    public var value: Bool { state.withLock { $0.value } }
    /// How many times the governor wrote. A clear that never had to happen is
    /// a bug worth seeing in a test.
    public var writes: Int { state.withLock { $0.writes } }

    /// Somebody else moved the flag while the helper was not looking.
    public func setExternally(_ disabled: Bool) {
        state.withLock { $0.value = disabled }
    }

    public func read() throws -> Bool {
        try state.withLock { state in
            if let failure = state.failure { throw SleepSwitchError(failure) }
            return state.value
        }
    }

    public func write(_ disabled: Bool) throws {
        try state.withLock { state in
            if let failure = state.failure { throw SleepSwitchError(failure) }
            state.value = disabled
            state.writes += 1
        }
    }
}

public struct SleepSwitchError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public final class InMemorySleepDisabledMarker: SleepDisabledMarker {
    private let marked: Mutex<Bool>

    public init(marked: Bool = false) {
        self.marked = Mutex(marked)
    }

    public var isMarked: Bool { marked.withLock { $0 } }
    public func mark() { marked.withLock { $0 = true } }
    public func unmark() { marked.withLock { $0 = false } }
}

/// The real marker: the existence of one empty file owned by root.
///
/// A file and not a preference, because the question it answers is asked by a
/// helper that has just started after a crash or a reboot, before anything
/// else runs.
public final class FileSleepDisabledMarker: SleepDisabledMarker {
    /// `/var/db` is where a launch daemon keeps this kind of state, and it is
    /// root-owned on every Mac.
    public static let defaultPath = "/var/db/com.serenearyal.vent.helper.sleep-disabled"

    private let url: URL

    public init(path: String = FileSleepDisabledMarker.defaultPath) {
        url = URL(filePath: path)
    }

    public var isMarked: Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    public func mark() {
        try? Data().write(to: url, options: .atomic)
    }

    public func unmark() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - The governor

/// Who is still connected, so the flag can be cleared when the last one goes.
///
/// The same shape as `FanClientRegistry`, and for the same reason: a client
/// that dies, is killed or crashes must not leave this Mac unable to sleep.
public struct SleepClientRegistry: Sendable, Equatable {
    private var tokens: Set<UInt64> = []

    public init() {}

    public var isEmpty: Bool { tokens.isEmpty }

    @discardableResult
    public mutating func add(_ token: UInt64) -> Bool {
        let wasEmpty = tokens.isEmpty
        return tokens.insert(token).inserted && wasEmpty
    }

    /// True when the last client just left.
    @discardableResult
    public mutating func remove(_ token: UInt64) -> Bool {
        guard tokens.remove(token) != nil else { return false }
        return tokens.isEmpty
    }
}

/// The flag, its marker, its clients and its guarantees, in one place.
///
/// The restore guarantees mirror the fans', because the danger is of the same
/// kind - a setting of Vent's that outlives Vent:
/// 1. The last XPC client goes away and the flag comes off.
/// 2. SIGTERM, SIGINT, SIGHUP and `atexit` clear it on the way out.
/// 3. A helper that starts and finds its own marker clears what the previous
///    run left behind, which covers a power cut and a `kill -9`.
/// 4. Nothing here ever clears a flag the marker does not claim.
public final class SleepDisabledGovernor: Sendable {
    private let power: any SystemSleepSwitch
    private let marker: any SleepDisabledMarker
    private let clients = Mutex(SleepClientRegistry())
    private let nextToken = Mutex<UInt64>(0)
    private let note: @Sendable (String) -> Void

    public init(
        power: any SystemSleepSwitch,
        marker: any SleepDisabledMarker,
        note: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.power = power
        self.marker = marker
        self.note = note
    }

    // MARK: Reading

    /// The flag and its owner. Nil only when the power manager would not say.
    public func report() -> SleepDisabledReport? {
        guard let isSet = try? power.read() else { return nil }
        return SleepDisabledReport(isSet: isSet, setByVent: isSet && marker.isMarked)
    }

    // MARK: Writing

    /// Sets or clears the flag. The reply is the reason it did not happen, or
    /// nil when the flag is now what was asked for.
    @discardableResult
    public func set(_ disabled: Bool) -> String? {
        disabled ? hold() : release()
    }

    private func hold() -> String? {
        let isSet: Bool
        do {
            isSet = try power.read()
        } catch {
            return Self.reason(error, doing: "read")
        }
        switch SleepDisabledPolicy.set(isSet: isSet, marked: marker.isMarked) {
        case .alreadyOurs:
            return nil
        case .foreign:
            note("sleep disabled is already set by somebody else; leaving it alone")
            return SleepDisabledPolicy.foreignMessage
        case .write:
            do {
                try power.write(true)
            } catch {
                return Self.reason(error, doing: "set")
            }
            // The marker after the write, never before: a marker without a
            // flag would make the next run clear somebody else's setting.
            marker.mark()
            note("sleep disabled set: this Mac stays awake with the lid closed")
            return nil
        }
    }

    /// Never an error the caller has to handle: every path that clears is a
    /// safety path, and one that refuses would leave the Mac unable to sleep.
    @discardableResult
    private func release() -> String? {
        let isSet: Bool
        do {
            isSet = try power.read()
        } catch {
            return Self.reason(error, doing: "read")
        }
        switch SleepDisabledPolicy.clear(isSet: isSet, marked: marker.isMarked) {
        case .notOurs:
            note("sleep disabled is set by somebody else; not clearing it")
            return SleepDisabledPolicy.foreignMessage
        case .nothingToClear:
            // A marker with no flag behind it is stale.
            if marker.isMarked { marker.unmark() }
            return nil
        case .clear:
            do {
                try power.write(false)
            } catch {
                return Self.reason(error, doing: "clear")
            }
            marker.unmark()
            note("sleep disabled cleared: this Mac sleeps as usual again")
            return nil
        }
    }

    // MARK: Guarantees

    /// Guarantee 3, at helper start: a marker from a previous run means that
    /// run died holding the flag.
    public func recoverAtStart() {
        guard marker.isMarked else { return }
        note("a previous run left sleep disabled set; clearing it")
        release()
    }

    /// Guarantee 1. One token per XPC connection, never a pid: two
    /// connections from one process have to count twice.
    public func clientArrived() -> UInt64 {
        let token = nextToken.withLock { value -> UInt64 in
            value += 1
            return value
        }
        clients.withLock { _ = $0.add(token) }
        return token
    }

    public func clientLeft(token: UInt64) {
        let wasLast = clients.withLock { $0.remove(token) }
        guard wasLast else { return }
        note("the last client is gone; clearing sleep disabled if it is ours")
        release()
    }

    /// Guarantee 2. Called from a signal handler and from `atexit`, so it does
    /// no queue hop and allocates nothing it does not have to.
    public func clearForTermination() {
        release()
    }

    private static func reason(_ error: any Error, doing what: String) -> String {
        let detail = (error as? SleepSwitchError)?.message ?? "\(error)"
        return "the power manager would not \(what) the system sleep setting: \(detail)"
    }
}
