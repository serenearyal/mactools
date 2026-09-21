import Foundation
import Synchronization

/// The system-wide `SleepDisabled` flag: what it means, who owns it, and the
/// rules that keep MacTools from ever clearing one it did not set.
///
/// This is what `sudo pmset disablesleep 1` writes. It is not an assertion: it
/// is a system power setting that stops the Mac sleeping at all, including on a
/// closed lid and on the Apple menu's Sleep, and it survives a reboot. Only
/// root can move it, so the privileged helper owns it and the app asks.
///
/// Why this lives in `HelperProtocol` rather than in `AwakeKit`: both ends of
/// the XPC call have to agree on the ownership rules, and `HelperProtocol` is
/// the one module the app, the helper, `mactoolsctl` and the tests all link. The
/// decisions are values and pure functions here, and the read of the flag is
/// here too because the app asks the same question. The write is in the helper
/// alone, behind `SystemSleepSwitch`, so no test can disable sleep on the
/// machine it runs on.

// MARK: - What the flag says

/// Who put the flag where it is.
public enum SleepDisabledOwner: String, Codable, Sendable, Equatable {
    /// The flag is clear: this Mac sleeps as usual.
    case nobody
    /// MacTools' helper set it, and MacTools will clear it again.
    case macTools
    /// Somebody else set it, `pmset` by hand being the usual way. MacTools leaves
    /// it strictly alone: it did not set it, so it is not MacTools' to undo.
    case somebodyElse
}

/// The flag and the helper's own marker, as one value. This is what crosses
/// the XPC link and what the UI reads.
public struct SleepDisabledReport: Codable, Sendable, Equatable {
    /// The `SleepDisabled` system power setting itself.
    public let isSet: Bool
    /// True when the helper's marker says this run, or a previous run of it,
    /// is the one that set the flag.
    public let setByMacTools: Bool

    public init(isSet: Bool, setByMacTools: Bool) {
        self.isSet = isSet
        self.setByMacTools = setByMacTools
    }

    public static let clear = SleepDisabledReport(isSet: false, setByMacTools: false)

    public var owner: SleepDisabledOwner {
        guard isSet else { return .nobody }
        return setByMacTools ? .macTools : .somebodyElse
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
    /// client that held it disconnecting, a signal, and the marker found at
    /// helper start.
    public static func clear(isSet: Bool, marked: Bool) -> ClearDecision {
        guard marked else { return isSet ? .notOurs : .nothingToClear }
        // Marked but clear means somebody else already undid it, or a flag
        // that was recorded as pending never got written; either way the
        // marker is stale and the governor drops it.
        return isSet ? .clear : .nothingToClear
    }

    /// What the helper answers, and the UI shows, when the flag is somebody
    /// else's. Nothing destructive is ever offered against it.
    public static let foreignMessage =
        "this Mac already has sleep disabled system-wide (pmset disablesleep 1); "
            + "MacTools did not set that and will not change it"
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

/// The one read of the flag on this Mac, for everybody who asks.
///
/// `IOPMCopySystemPowerSettings` is exported by IOKit and declared in no public
/// header, so it is reached through `dlsym` rather than by redeclaring the
/// symbol: a wrong redeclaration is a link error at best and a crash at worst.
/// Parsing `pmset -g` would mean a subprocess for one integer.
///
/// It lives here because two processes ask the same question: the helper, to
/// decide whether it may write the flag, and the app, to say on the Keep Awake
/// tab what is holding this Mac awake. One copy of an unsupported symbol
/// lookup is enough. Reading needs no privilege; the write stays in the helper
/// target, where no test can reach it.
public enum SystemSleepFlag {
    /// `kIOPMSleepDisabledKey`, from `IOPMLibPrivate.h`.
    public static let key = "SleepDisabled"

    private typealias Copy = @convention(c) () -> Unmanaged<CFDictionary>?

    /// Throws when IOKit has no such symbol, or the power manager says nothing
    /// at all. A Mac that has never had the flag written has no such key, and
    /// that is a clear flag, not a failure.
    public static func read() throws -> Bool {
        // `RTLD_DEFAULT`, which Swift does not name.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPMCopySystemPowerSettings") else {
            throw SleepSwitchError("IOPMCopySystemPowerSettings is not in this IOKit")
        }
        let copy = unsafeBitCast(symbol, to: Copy.self)
        guard let settings = copy()?.takeRetainedValue() as? [String: Any] else {
            throw SleepSwitchError("the power manager returned no system settings")
        }
        guard let value = settings[key] as? NSNumber else { return false }
        return value.boolValue
    }

    /// The same read for a caller that has nothing to do with a failure: nil
    /// when the power manager would not say.
    public static func value() -> Bool? { try? read() }
}

/// The helper's memory of "I set it", kept across a restart of the helper and
/// across a reboot, because the flag itself is.
///
/// `mark()` and `unmark()` throw, and the governor treats a failed mark as a
/// refusal to set the flag at all. A mark that quietly did not happen is the
/// worst state this file can produce: a Mac that cannot sleep, with nothing
/// left on disk that admits MacTools is the one holding it.
public protocol SleepDisabledMarker: Sendable {
    var isMarked: Bool { get }
    func mark() throws
    func unmark() throws
}

/// The marker would not move. Kept apart from `SleepSwitchError` because the
/// two failures mean different things: this one leaves the flag alone.
public struct SleepMarkerError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
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

/// The marker of the tests. `failure` makes every `mark` and `unmark` fail,
/// which is the case that must never end with the flag set.
public final class InMemorySleepDisabledMarker: SleepDisabledMarker {
    private let state: Mutex<(marked: Bool, failure: String?)>

    public init(marked: Bool = false, failure: String? = nil) {
        state = Mutex((marked: marked, failure: failure))
    }

    public var isMarked: Bool { state.withLock { $0.marked } }

    public func mark() throws {
        try state.withLock { state in
            if let failure = state.failure { throw SleepMarkerError(failure) }
            state.marked = true
        }
    }

    public func unmark() throws {
        try state.withLock { state in
            if let failure = state.failure { throw SleepMarkerError(failure) }
            state.marked = false
        }
    }
}

/// The real marker: the existence of one empty file owned by root.
///
/// A file and not a preference, because the question it answers is asked by a
/// helper that has just started after a crash or a reboot, before anything
/// else runs.
///
/// Both writes report what went wrong. A marker that cannot be written is the
/// reason the flag is not written either, and the caller has to be able to say
/// so.
public final class FileSleepDisabledMarker: SleepDisabledMarker {
    /// `/var/db` is where a launch daemon keeps this kind of state, and it is
    /// root-owned on every Mac.
    public static let defaultPath = "/var/db/com.serenearyal.mactools.helper.sleep-disabled"

    private let url: URL

    public init(path: String = FileSleepDisabledMarker.defaultPath) {
        url = URL(filePath: path)
    }

    public var path: String { url.path(percentEncoded: false) }

    public var isMarked: Bool { FileManager.default.fileExists(atPath: path) }

    public func mark() throws {
        do {
            try Data().write(to: url, options: .atomic)
        } catch {
            throw SleepMarkerError("\(path) could not be written: \(error.localizedDescription)")
        }
    }

    public func unmark() throws {
        guard isMarked else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw SleepMarkerError("\(path) could not be removed: \(error.localizedDescription)")
        }
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

/// The flag, its marker, its holders and its guarantees, in one place.
///
/// The restore guarantees mirror the fans', because the danger is of the same
/// kind - a setting of MacTools' that outlives MacTools:
/// 1. The flag is held per connection. It is set while at least one connection
///    that asked for it is alive and has not let go, and it comes off the
///    moment the last of them releases it or disconnects. A `mactoolsctl` that
///    exits therefore takes its own hold with it and nobody else's.
/// 2. SIGTERM, SIGINT, SIGHUP and `atexit` clear it on the way out.
/// 3. A helper that starts and finds its own marker clears what the previous
///    run left behind, which covers a power cut and a `kill -9`. `RunAtLoad`
///    in the daemon plist is what makes that happen at boot rather than at the
///    first connection.
/// 4. Nothing here ever clears a flag the marker does not claim.
///
/// Concurrency: one `Mutex` owns every decision, the two IOKit calls and the
/// marker included, and every entry point goes through it. XPC calls these
/// methods on its own queues, and a read-decide-write that can interleave with
/// another one is exactly how a flag ends up set with no client behind it.
/// The same reason `FanCoordinator` puts one serial queue around the SMC.
public final class SleepDisabledGovernor: Sendable {
    private let power: any SystemSleepSwitch
    private let marker: any SleepDisabledMarker
    private let state: Mutex<State>
    private let note: @Sendable (String) -> Void

    /// Everything the lock owns. Nothing here is read without it.
    private struct State: Sendable {
        var clients = SleepClientRegistry()
        /// The connections that asked for the flag and have not let go.
        var holders: Set<UInt64> = []
        var nextToken: UInt64 = 0
    }

    public init(
        power: any SystemSleepSwitch,
        marker: any SleepDisabledMarker,
        note: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.power = power
        self.marker = marker
        self.note = note
        state = Mutex(State())
    }

    /// How many connections are holding the flag. For the tests and the log.
    public var holdCount: Int { state.withLock { $0.holders.count } }

    // MARK: Reading

    /// The flag and its owner. Nil only when the power manager would not say.
    ///
    /// This is also where a stale marker dies, and that is the point: a marker
    /// that outlived its flag would let MacTools clear a flag the user sets by
    /// hand later.
    public func report() -> SleepDisabledReport? {
        state.withLock { _ in lockedReport() }
    }

    // MARK: Writing

    /// Sets or clears the flag for one connection. The reply is the reason it
    /// did not happen, or nil when the flag is now what that connection asked
    /// for. Clearing with another connection still holding is not a failure:
    /// this connection's hold is gone and the flag stays for the other one.
    @discardableResult
    public func set(_ disabled: Bool, client token: UInt64) -> String? {
        state.withLock { state in
            disabled ? lockedHold(token, &state) : lockedRelease(token, &state)
        }
    }

    // MARK: Guarantees

    /// Guarantee 3, at helper start: a marker from a previous run means that
    /// run died holding the flag.
    public func recoverAtStart() {
        state.withLock { state in
            guard marker.isMarked else { return }
            note("a previous run left sleep disabled set; clearing it")
            _ = lockedClear(&state)
        }
    }

    /// Guarantee 1. One token per XPC connection, never a pid: two
    /// connections from one process have to count twice.
    public func clientArrived() -> UInt64 {
        state.withLock { state in
            state.nextToken += 1
            let token = state.nextToken
            state.clients.add(token)
            return token
        }
    }

    /// Guarantee 1. A connection that leaves gives up its own hold, and the
    /// flag comes off when that was the last one holding it.
    public func clientLeft(token: UInt64) {
        state.withLock { state in
            let wasHolding = state.holders.remove(token) != nil
            let wasLast = state.clients.remove(token)
            guard wasHolding || wasLast else { return }
            guard state.holders.isEmpty else {
                note("a client holding sleep disabled left; another client still holds it")
                return
            }
            note("nobody is holding sleep disabled any more; clearing it if it is ours")
            _ = lockedClear(&state)
        }
    }

    /// Guarantee 2, from the signal path and from `atexit`. The caller puts a
    /// deadline around it: the write goes through powerd and is not bounded.
    public func clearForTermination() {
        state.withLock { state in _ = lockedClear(&state) }
    }

    // MARK: - Under the lock

    /// The flag, and the one place a stale marker is dropped.
    ///
    /// The window this leaves is worth stating plainly: between this read and
    /// the next write of the governor, the user can clear the flag with
    /// `pmset` and set it again by hand, and MacTools would then clear a flag that
    /// is no longer its own. It is the gap between two reads, not the length
    /// of a Keep Awake session, because the app reads the state on every pass
    /// of the tab and every clear path reads it again before it writes.
    private func lockedReport() -> SleepDisabledReport? {
        guard let isSet = try? power.read() else { return nil }
        guard marker.isMarked else { return SleepDisabledReport(isSet: isSet, setByMacTools: false) }
        guard isSet else {
            // Somebody cleared the flag behind us, or a write failed after the
            // marker was written. Either way the marker claims nothing now.
            try? marker.unmark()
            note("the marker outlived its flag; dropping it")
            return SleepDisabledReport.clear
        }
        return SleepDisabledReport(isSet: true, setByMacTools: true)
    }

    /// One connection asks for the flag.
    private func lockedHold(_ token: UInt64, _ state: inout State) -> String? {
        let isSet: Bool
        do {
            isSet = try power.read()
        } catch {
            return Self.reason(error, doing: "read")
        }
        switch SleepDisabledPolicy.set(isSet: isSet, marked: marker.isMarked) {
        case .alreadyOurs:
            state.holders.insert(token)
            return nil
        case .foreign:
            note("sleep disabled is already set by somebody else; leaving it alone")
            return SleepDisabledPolicy.foreignMessage
        case .write:
            // The marker first, and it has to succeed. A flag written before
            // its marker is an orphan if the process dies in between: every
            // clear path would then call it somebody else's and this Mac would
            // never sleep again. A marker with no flag behind it is the
            // harmless way round - the next read drops it.
            do {
                try marker.mark()
            } catch {
                return "the helper could not record that it set the system sleep setting, "
                    + "so it did not set it: \(Self.detail(error))"
            }
            do {
                try power.write(true)
            } catch {
                try? marker.unmark()
                return Self.reason(error, doing: "set")
            }
            state.holders.insert(token)
            note("sleep disabled set: this Mac stays awake with the lid closed")
            return nil
        }
    }

    /// One connection lets go. The flag stays while anybody else holds it.
    private func lockedRelease(_ token: UInt64, _ state: inout State) -> String? {
        state.holders.remove(token)
        guard state.holders.isEmpty else {
            note("a client let go of sleep disabled; another client still holds it")
            return nil
        }
        return lockedClear(&state)
    }

    /// Every way the flag comes off ends here: the last holder letting go or
    /// leaving, a signal, `atexit`, and the marker found at start.
    private func lockedClear(_ state: inout State) -> String? {
        state.holders.removeAll()
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
            if marker.isMarked { try? marker.unmark() }
            return nil
        case .clear:
            do {
                try power.write(false)
            } catch {
                // The marker stays: the flag is still set and still ours, and
                // the next clear path, or the next helper start, has to know.
                return Self.reason(error, doing: "clear")
            }
            // The marker last, for the same reason it goes first on the way
            // up: a death between the two leaves a marker with no flag, which
            // the next read drops, and never a flag with no marker.
            try? marker.unmark()
            note("sleep disabled cleared: this Mac sleeps as usual again")
            return nil
        }
    }

    private static func reason(_ error: any Error, doing what: String) -> String {
        "the power manager would not \(what) the system sleep setting: \(detail(error))"
    }

    private static func detail(_ error: any Error) -> String {
        if let error = error as? SleepSwitchError { return error.message }
        if let error = error as? SleepMarkerError { return error.message }
        return "\(error)"
    }
}
