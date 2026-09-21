import Darwin
import Foundation
import Synchronization
import os

import FanControl
import HelperProtocol
import SMCKit
import SysMetrics

/// The one logger of the helper process.
///
/// `log stream --predicate 'subsystem == "com.serenearyal.mactools"'` shows the app
/// and the helper together, which is what a fan bug needs.
enum HelperLog {
    static let logger = Logger(subsystem: HelperConstants.appBundleIdentifier, category: "helper")
    /// The fan governor logs under the category the app uses for it, so one
    /// stream shows both ends of a mode change.
    static let fans = Logger(subsystem: HelperConstants.appBundleIdentifier, category: "fans")
}

/// Marketing version and build of this binary, read from the Info.plist
/// section linked into the executable.
enum HelperBuild {
    static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short)+\(build)"
    }()
}

/// The object the helper exports over XPC.
///
/// Concurrency: XPC calls these methods on its own queues. Every stored
/// property is immutable, `SMCConnection` locks around the driver call and the
/// fan coordinator owns a serial queue of its own, so this class needs none.
/// `@unchecked` because `NSObject` is not `Sendable`.
final class HelperService: NSObject, MacToolsHelperProtocol, @unchecked Sendable {
    /// One connection for the life of the process: opening the user client
    /// costs a mach round trip and the daemon may answer thousands of reads.
    private let smc: SMCConnection?
    private let smcError: String?
    private let log = HelperLog.logger
    /// One sampler for the life of the helper: the CPU percent of a process is
    /// a delta, and a fresh sampler per call would only ever report nil.
    private let processes = ProcessSampler()

    /// nil when the SMC would not describe its fans. Every fan method then
    /// answers with `fanError`.
    let fans: FanCoordinator?
    private let fanError: String?
    /// The system-wide sleep setting, with its ownership marker and its
    /// restore guarantees. Nil in a build that has no business writing it.
    let sleep: SleepDisabledGovernor?
    /// False only for the XPC round-trip test, which runs as a normal user
    /// against a fake. The daemon always builds itself through `init()`.
    private let requiresRoot: Bool
    /// The signal sources of the termination guarantees, kept alive for the
    /// life of the process.
    private let signalSources = Mutex<[DispatchSourceSignal]>([])
    private let terminationQueue = DispatchQueue(
        label: "\(HelperConstants.helperBundleIdentifier).termination"
    )
    /// Set once the sleep flag has been cleared on the way out, so the signal
    /// path and `atexit` do not both wait on powerd for the same clear.
    private let sleepClearedOnTheWayOut = Mutex(false)
    /// The tokens of each live connection, so a call can be charged to the
    /// connection that made it. `NSXPCConnection.current()` inside a method is
    /// the same object the listener delegate accepted.
    private let tokensByConnection = Mutex<[ConnectionKey: ClientTokens]>([:])

    /// The one service of the process, for the C-level handlers that have
    /// nowhere to carry context.
    static let shared = Mutex<HelperService?>(nil)

    /// The designated initializer. Everything this service talks to is handed
    /// to it: it opens no SMC connection and looks for no fan by itself.
    ///
    /// That is deliberate. The one place the real hardware is built is
    /// `HelperService.daemon()`, in a file only the helper target compiles, so
    /// a test can never end up writing to a fan of this Mac by accident - not
    /// even the unprivileged write that fails and logs.
    init(
        smc: SMCConnection?,
        smcError: String?,
        fanHardware: (any FanHardware)?,
        fanError: String?,
        sleep: SleepDisabledGovernor?,
        requiresRoot: Bool
    ) {
        self.requiresRoot = requiresRoot
        self.smc = smc
        self.smcError = smcError
        fans = fanHardware.map { FanCoordinator(hardware: $0) }
        self.fanError = fans == nil ? (fanError ?? "the fans are not reachable") : nil
        self.sleep = sleep
        super.init()
    }

    /// The service a test builds: fans that exist only in the caller's
    /// process, a sleep setting that exists only in memory, and no SMC
    /// connection of any kind.
    convenience init(
        fanHardware: any FanHardware,
        sleep: SleepDisabledGovernor? = nil,
        requiresRoot: Bool
    ) {
        self.init(
            smc: nil,
            smcError: "this build of the helper has no SMC connection",
            fanHardware: fanHardware,
            fanError: nil,
            sleep: sleep,
            requiresRoot: requiresRoot
        )
    }

    // MARK: - Lifetime

    /// Guarantee 2 for both the fans and the sleep setting: SIGTERM, SIGINT,
    /// SIGHUP and every other way out put this Mac back the way it was found.
    ///
    /// `SIG_IGN` first, because a `DispatchSourceSignal` only sees the signal
    /// once the default action is out of the way, and that default is to kill
    /// the process before anything is restored.
    ///
    /// One owner for both, and it is this class: two sets of handlers on one
    /// signal would race to call `exit(0)`, and the loser would restore
    /// nothing. The fans keep their own hardware knowledge; this decides when.
    /// The fans go first on every way out, and that order is deliberate: an
    /// SMC write is a local driver call that takes microseconds, while the
    /// sleep flag goes to powerd over IPC and is bounded by nothing. A fan
    /// left forced is the faster way to cook this Mac, so it is never made to
    /// wait behind a power manager that is busy.
    func installTerminationHandlers() {
        let sources = [SIGTERM, SIGINT, SIGHUP].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: terminationQueue)
            source.setEventHandler { [weak self] in
                self?.log.notice(
                    "signal \(number, privacy: .public): every fan to Auto, then clearing sleep disabled"
                )
                self?.fans?.restoreAllAutoOnSignal()
                self?.clearSleepBeforeExit()
                exit(0)
            }
            source.resume()
            return source
        }
        signalSources.withLock { $0 = sources }

        HelperService.shared.withLock { $0 = self }
        // The last net: a normal exit, or one from a path that did not go
        // through a signal. A C function pointer carries no context, hence the
        // static above.
        atexit {
            guard let service = HelperService.shared.withLock({ $0 }) else { return }
            service.fans?.restoreAllAutoNow()
            service.clearSleepBeforeExit()
        }
    }

    /// How long the way out waits for the power manager. Long enough for a
    /// call that answers, short enough that nothing else on the way out is
    /// held up by one that does not.
    private static let sleepClearDeadline = DispatchTimeInterval.seconds(2)

    /// Clears the sleep flag with a deadline, once per process.
    ///
    /// `IOPMSetSystemPowerSetting` is a round trip to powerd, and a daemon
    /// that hangs there on SIGTERM is one launchd kills with SIGKILL a few
    /// seconds later - after which nothing of this process runs at all. If the
    /// deadline passes the marker file is still on disk, so the next start of
    /// the helper clears the flag (guarantee 3), and `RunAtLoad` means that
    /// start happens at boot rather than at the first connection.
    private func clearSleepBeforeExit() {
        guard let sleep, !sleepClearedOnTheWayOut.withLock({ $0 }) else { return }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            sleep.clearForTermination()
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.sleepClearDeadline) == .success else {
            log.error("the power manager did not clear sleep disabled in time; the marker survives for the next start")
            return
        }
        sleepClearedOnTheWayOut.withLock { $0 = true }
    }

    /// Guarantee 3 at start, for both: whatever a previous run left behind is
    /// undone before the first client can connect.
    ///
    /// The fans first here too, and for the reason they go first on the way
    /// out: the SMC is local and answers at once, while the sleep recovery
    /// goes to powerd. A fan a killed run left forced must not wait behind it.
    func restoreAtStart() {
        fans?.startWithAutoRestore()
        sleep?.recoverAtStart()
    }

    /// Guarantee 1: one token per XPC connection, so the last client to leave
    /// takes the fans with it and every connection takes its own sleep hold.
    ///
    /// The connection is remembered here as well, because the sleep flag is
    /// held per connection: the method that sets it has to know which one is
    /// asking, and `NSXPCConnection.current()` gives it the same object.
    func clientArrived(_ connection: NSXPCConnection? = nil) -> ClientTokens {
        let tokens = ClientTokens(fans: fans?.clientArrived(), sleep: sleep?.clientArrived())
        if let connection {
            tokensByConnection.withLock { $0[Self.key(for: connection)] = tokens }
        }
        return tokens
    }

    func clientLeft(_ tokens: ClientTokens, from key: ConnectionKey? = nil) {
        if let key {
            tokensByConnection.withLock { $0[key] = nil }
        }
        if let token = tokens.fans { fans?.clientLeft(token: token) }
        if let token = tokens.sleep { sleep?.clientLeft(token: token) }
    }

    /// How many connections the service is tracking. The XPC tests wait on it
    /// to know that an invalidation handler has run.
    var liveConnections: Int { tokensByConnection.withLock { $0.count } }

    /// How one connection is named in the table above. An identity, not a
    /// reference: nothing here keeps a connection alive, and the entry is
    /// dropped on invalidation, which happens while the object is still there.
    typealias ConnectionKey = ObjectIdentifier

    static func key(for connection: NSXPCConnection) -> ConnectionKey {
        ObjectIdentifier(connection)
    }

    /// The tokens of one connection: one per thing that has to be given back.
    struct ClientTokens: Sendable {
        let fans: UInt64?
        let sleep: UInt64?
    }

    // MARK: - MacToolsHelperProtocol

    func ping(reply: @escaping @Sendable (String) -> Void) {
        let euid = geteuid()
        log.debug("ping from a client, euid \(euid, privacy: .public)")
        reply("pong \(HelperBuild.version) uid=\(euid)")
    }

    func helperVersion(reply: @escaping @Sendable (String) -> Void) {
        reply(HelperBuild.version)
    }

    func readSMCKey(_ key: String, reply: @escaping @Sendable (Data?, String?) -> Void) {
        if let failure = privilegeFailure() {
            reply(nil, failure)
            return
        }
        guard let code = SMCFourCC(code: key) else {
            reply(nil, "'\(key)' is not a four-character SMC key")
            return
        }
        guard let smc else {
            reply(nil, smcError ?? "the SMC is not reachable")
            return
        }
        do {
            let info = try smc.keyInfo(for: code)
            reply(Data(try smc.readBytes(code, info: info)), nil)
        } catch {
            log.error("read \(key, privacy: .public) failed: \(error.description, privacy: .public)")
            reply(nil, error.description)
        }
    }

    // MARK: - Fans

    func fanSnapshot(reply: @escaping @Sendable (Data?, String?) -> Void) {
        guard let fans, privilegeFailure() == nil else {
            reply(nil, privilegeFailure() ?? fanError)
            return
        }
        guard let data = fans.snapshot().jsonData else {
            reply(nil, "the fan snapshot could not be encoded")
            return
        }
        reply(data, nil)
    }

    func setFanMode(fanIndex: Int, modeJSON: Data, reply: @escaping @Sendable (String?) -> Void) {
        guard let fans, privilegeFailure() == nil else {
            reply(privilegeFailure() ?? fanError)
            return
        }
        guard let mode = FanMode(json: modeJSON) else {
            reply("the fan mode could not be decoded")
            return
        }
        reply(fans.setMode(mode, forFan: fanIndex))
    }

    /// Never refused for lack of root: the answer would be the same either
    /// way, and a client that is trying to make the fans safe deserves a
    /// plain reply.
    func restoreAllAuto(reply: @escaping @Sendable (String?) -> Void) {
        guard let fans else {
            reply(fanError)
            return
        }
        reply(fans.restoreAllAuto())
    }

    // MARK: - Sleep

    /// The `SleepDisabled` flag and who owns it. Read only, and it needs root
    /// like everything else here: `IOPMCopySystemPowerSettings` is readable by
    /// anyone, but the marker that says whether MacTools set it is not.
    func sleepDisabledState(reply: @escaping @Sendable (Data?, String?) -> Void) {
        if let failure = privilegeFailure() {
            reply(nil, failure)
            return
        }
        guard let sleep else {
            reply(nil, Self.noSleepControl)
            return
        }
        guard let report = sleep.report() else {
            reply(nil, "the power manager would not say whether sleep is disabled")
            return
        }
        guard let data = try? JSONEncoder().encode(report) else {
            reply(nil, "the sleep setting could not be encoded")
            return
        }
        reply(data, nil)
    }

    /// The one write in this helper that changes how the whole Mac behaves, so
    /// every call is logged with the client that asked for it.
    ///
    /// The hold belongs to the connection, not to the helper: the flag is set
    /// while at least one connection that asked for it is alive, and this call
    /// only ever adds or drops the caller's own hold. That is what makes
    /// `mactoolsctl awake lid off` mean "I am done with it" rather than "clear it
    /// even though the app is holding it", and what makes a `mactoolsctl` that
    /// exits take nothing but its own hold with it.
    ///
    /// Clearing is never refused for lack of root in spirit - but it does need
    /// root to happen at all, so the gate stands and the answer says so.
    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (String?) -> Void) {
        if let failure = privilegeFailure() {
            reply(failure)
            return
        }
        guard let sleep else {
            reply(Self.noSleepControl)
            return
        }
        let connection = NSXPCConnection.current()
        guard let token = connection.flatMap({ tokens(for: $0)?.sleep }) else {
            // No connection means no owner for the hold, and a hold nobody
            // owns is one nothing would ever give back.
            reply("the helper cannot tell which connection is asking for the sleep setting")
            return
        }
        let client = connection?.processIdentifier ?? -1
        let failure = sleep.set(disabled, client: token)
        log.notice(
            """
            sleep disabled \(disabled ? "held" : "released", privacy: .public) by client pid \
            \(client, privacy: .public): \(failure ?? "done", privacy: .public), \
            \(sleep.holdCount, privacy: .public) holder(s) left
            """
        )
        reply(failure)
    }

    private func tokens(for connection: NSXPCConnection) -> ClientTokens? {
        tokensByConnection.withLock { $0[Self.key(for: connection)] }
    }

    private static let noSleepControl = "this build of the helper does not control the sleep setting"

    // MARK: - Processes

    /// The rows of every process the calling user does not own, sampled as
    /// root so the CPU and memory counters libproc refuses the app are filled
    /// in.
    ///
    /// The uid comes from the connection, never from the argument: a client
    /// that asked for uid 0 to be excluded would otherwise be handed the whole
    /// table, its own rows included, for nothing.
    func processSnapshot(excludingUID: UInt32, reply: @escaping @Sendable (Data?, String?) -> Void) {
        if let failure = privilegeFailure() {
            reply(nil, failure)
            return
        }
        guard let connection = NSXPCConnection.current() else {
            reply(nil, "the helper cannot tell which user is calling")
            return
        }
        let caller = connection.effectiveUserIdentifier
        if caller != excludingUID {
            log.error(
                """
                client pid \(connection.processIdentifier, privacy: .public) claims uid \
                \(excludingUID, privacy: .public) on a connection of uid \(caller, privacy: .public); \
                the connection wins
                """
            )
        }
        do {
            let rows = try processes.sample().filter { $0.uid != caller }
            guard let data = try? JSONEncoder().encode(rows) else {
                reply(nil, "the process list could not be encoded")
                return
            }
            log.debug("process snapshot: \(rows.count, privacy: .public) rows for uid \(caller, privacy: .public)")
            reply(data, nil)
        } catch {
            log.error("the process table failed: \(error.description, privacy: .public)")
            reply(nil, error.description)
        }
    }

    /// SIGTERM or SIGKILL, and nothing else. Every call is logged with the
    /// client that asked for it, granted or refused: this is the one method
    /// that ends somebody else's work.
    func signalProcess(pid: Int32, signal: Int32, reply: @escaping @Sendable (String?) -> Void) {
        if let failure = privilegeFailure() {
            reply(failure)
            return
        }
        let client = NSXPCConnection.current()?.processIdentifier ?? -1
        if let refusal = ProcessSignalPolicy.refusal(pid: pid, signal: signal, senderPID: getpid()) {
            log.error(
                """
                refused signal \(signal, privacy: .public) to pid \(pid, privacy: .public) \
                for client pid \(client, privacy: .public): \(refusal, privacy: .public)
                """
            )
            reply(refusal)
            return
        }
        let failure = ProcessSignalPolicy.send(pid: pid, signal: signal)
        log.notice(
            """
            signal \(signal, privacy: .public) to pid \(pid, privacy: .public) \
            for client pid \(client, privacy: .public): \(failure ?? "sent", privacy: .public)
            """
        )
        reply(failure)
    }

    // MARK: - Privilege

    /// The reason a privileged call must be refused, or nil when it may run.
    ///
    /// Everything this helper exists for needs root. Without it the process is
    /// still useful: it answers `ping` and `helperVersion`, so the XPC path can
    /// be exercised from a test that is not root.
    private func privilegeFailure() -> String? {
        let euid = geteuid()
        guard !requiresRoot || euid == 0 else {
            return "the helper is not running as root (euid \(euid)); install it from the Settings tab"
        }
        return nil
    }
}
