import Foundation
import Testing

import HelperProtocol

/// The system-wide `SleepDisabled` flag: who may set it, who may clear it, and
/// every way it comes back off.
///
/// Driven by `InMemorySleepSwitch`, in the spirit of `InMemoryFanHardware`: the
/// real setting stops the machine running the test from ever sleeping, so no
/// test here goes near it.
@Suite("Sleep disabled")
struct SleepDisabledTests {
    /// A governor with one client already connected, which is what every
    /// caller of `set` is: the hold belongs to a connection.
    private func makeGovernor(
        flag: Bool = false,
        marked: Bool = false,
        markerFailure: String? = nil
    ) -> (SleepDisabledGovernor, InMemorySleepSwitch, InMemorySleepDisabledMarker, UInt64) {
        let power = InMemorySleepSwitch(disabled: flag)
        let marker = InMemorySleepDisabledMarker(marked: marked, failure: markerFailure)
        let governor = SleepDisabledGovernor(power: power, marker: marker)
        return (governor, power, marker, governor.clientArrived())
    }

    // MARK: - The rules

    @Test("a clear flag may be written")
    func policySetsAClearFlag() {
        #expect(SleepDisabledPolicy.set(isSet: false, marked: false) == .write)
        #expect(SleepDisabledPolicy.set(isSet: false, marked: true) == .write)
    }

    @Test("a flag that is already ours is left where it is")
    func policySetsNothingTwice() {
        #expect(SleepDisabledPolicy.set(isSet: true, marked: true) == .alreadyOurs)
    }

    @Test("a flag somebody else set is never written over and never cleared")
    func policyLeavesAForeignFlagAlone() {
        #expect(SleepDisabledPolicy.set(isSet: true, marked: false) == .foreign)
        #expect(SleepDisabledPolicy.clear(isSet: true, marked: false) == .notOurs)
    }

    @Test("only a marked flag is cleared")
    func policyClearsOnlyOurs() {
        #expect(SleepDisabledPolicy.clear(isSet: true, marked: true) == .clear)
        #expect(SleepDisabledPolicy.clear(isSet: false, marked: true) == .nothingToClear)
        #expect(SleepDisabledPolicy.clear(isSet: false, marked: false) == .nothingToClear)
    }

    // MARK: - Setting and clearing

    @Test("setting the flag writes it once and takes ownership")
    func setsAndOwns() {
        let (governor, power, marker, client) = makeGovernor()
        #expect(governor.set(true, client: client) == nil)
        #expect(power.value)
        #expect(power.writes == 1)
        #expect(marker.isMarked)
        #expect(governor.report() == SleepDisabledReport(isSet: true, setByMacTools: true))
        #expect(governor.report()?.owner == .macTools)
        #expect(governor.holdCount == 1)

        // Asking again changes nothing at all.
        #expect(governor.set(true, client: client) == nil)
        #expect(power.writes == 1)
        #expect(governor.holdCount == 1)
    }

    @Test("clearing the flag writes it back and gives up ownership")
    func clearsWhatItSet() {
        let (governor, power, marker, client) = makeGovernor()
        governor.set(true, client: client)
        #expect(governor.set(false, client: client) == nil)
        #expect(!power.value)
        #expect(power.writes == 2)
        #expect(!marker.isMarked)
        #expect(governor.report()?.owner == .nobody)
        #expect(governor.holdCount == 0)
    }

    @Test("a flag pmset set is reported, refused and never touched")
    func refusesAForeignFlag() {
        let (governor, power, marker, client) = makeGovernor(flag: true)
        #expect(governor.report() == SleepDisabledReport(isSet: true, setByMacTools: false))
        #expect(governor.report()?.owner == .somebodyElse)

        #expect(governor.set(true, client: client) == SleepDisabledPolicy.foreignMessage)
        #expect(governor.set(false, client: client) == SleepDisabledPolicy.foreignMessage)
        #expect(power.value, "the user's own setting is still there")
        #expect(power.writes == 0)
        #expect(!marker.isMarked)
        #expect(governor.holdCount == 0, "a refused hold is not a hold")
    }

    /// The dangerous order: MacTools sets the flag, the user runs `pmset` to clear
    /// it, and the marker is now a lie. Nothing may be written because of it.
    @Test("a marker with no flag behind it is dropped, not acted on")
    func staleMarkerIsDropped() {
        let (governor, power, marker, client) = makeGovernor()
        governor.set(true, client: client)
        power.setExternally(false)

        #expect(governor.set(false, client: client) == nil)
        #expect(power.writes == 1, "there was nothing left to clear")
        #expect(!marker.isMarked)
    }

    /// The reason the stale marker is dropped at every read rather than only
    /// on the way out: the user clears the flag by hand, MacTools reads the state
    /// once, the user sets it again by hand, and MacTools' own release must then
    /// leave that flag exactly where it is.
    @Test("a flag the user sets again by hand after a read is never cleared by MacTools")
    func aReadDropsTheMarkerSoALaterForeignFlagSurvives() {
        let (governor, power, marker, client) = makeGovernor()
        governor.set(true, client: client)

        power.setExternally(false)
        #expect(governor.report() == SleepDisabledReport.clear, "the flag is off, whoever turned it off")
        #expect(!marker.isMarked, "the marker died with the flag it claimed")

        // `sudo pmset disablesleep 1`, by hand, after that read.
        power.setExternally(true)
        #expect(governor.report()?.owner == .somebodyElse)
        #expect(governor.set(false, client: client) == SleepDisabledPolicy.foreignMessage)
        governor.clearForTermination()
        #expect(power.value, "the user's own flag is still there")
        #expect(power.writes == 1, "only MacTools' own write ever happened")
    }

    @Test("a power manager that refuses says so and owns nothing")
    func aRefusedWriteIsReported() {
        let power = InMemorySleepSwitch(failure: "not permitted")
        let marker = InMemorySleepDisabledMarker()
        let governor = SleepDisabledGovernor(power: power, marker: marker)
        let failure = governor.set(true, client: governor.clientArrived())
        #expect(failure?.contains("not permitted") == true)
        #expect(!marker.isMarked)
        #expect(governor.report() == nil)
    }

    /// The marker is the only thing that lets a later run recognise its own
    /// flag, so a marker that cannot be written means no flag at all.
    @Test("a marker that cannot be written leaves the flag off and says why")
    func aMarkerThatFailsStopsTheWrite() {
        let (governor, power, marker, client) = makeGovernor(markerFailure: "/var/db is read only")
        let failure = governor.set(true, client: client)
        #expect(failure?.contains("read only") == true)
        #expect(failure?.contains("did not set it") == true)
        #expect(!power.value, "a flag nothing claims must never be set")
        #expect(power.writes == 0)
        #expect(!marker.isMarked)
        #expect(governor.holdCount == 0)
    }

    /// The write fails after the marker went down. The marker claims a flag
    /// that is not set, which is the harmless way round: the next read drops
    /// it, and no clear path acts on it.
    @Test("a flag that could not be written leaves no marker behind")
    func aFailedWriteDropsThePendingMarker() {
        let power = InMemorySleepSwitch(failure: "not permitted")
        let marker = InMemorySleepDisabledMarker()
        let governor = SleepDisabledGovernor(power: power, marker: marker)
        _ = governor.set(true, client: governor.clientArrived())
        #expect(!marker.isMarked)
    }

    // MARK: - One hold per connection

    /// R-10: `mactoolsctl awake lid on` must not leave the flag set after it
    /// exits, and `mactoolsctl awake lid off` must not turn the app's hold off.
    @Test("the flag is held while any one connection holds it")
    func twoClientsHoldSeparately() {
        let (governor, power, _, app) = makeGovernor()
        let cli = governor.clientArrived()

        #expect(governor.set(true, client: app) == nil)
        #expect(governor.set(true, client: cli) == nil)
        #expect(power.writes == 1, "the second hold needs no second write")
        #expect(governor.holdCount == 2)

        // mactoolsctl exits: its connection drops, and only its own hold with it.
        governor.clientLeft(token: cli)
        #expect(power.value, "the app is still holding it")
        #expect(governor.holdCount == 1)

        governor.clientLeft(token: app)
        #expect(!power.value)
    }

    @Test("a client that never asked for the flag takes nothing with it")
    func aNonHolderLeavingKeepsTheFlag() {
        let (governor, power, _, app) = makeGovernor()
        let watcher = governor.clientArrived()
        governor.set(true, client: app)

        governor.clientLeft(token: watcher)
        #expect(power.value, "the client that left was not holding anything")

        governor.clientLeft(token: app)
        #expect(!power.value)
    }

    @Test("one client releasing does not clear a flag another still holds")
    func oneReleaseIsNotEverybodysRelease() {
        let (governor, power, _, app) = makeGovernor()
        let cli = governor.clientArrived()
        governor.set(true, client: app)
        governor.set(true, client: cli)

        #expect(governor.set(false, client: cli) == nil, "letting go is never a failure")
        #expect(power.value, "the app still holds it")
        #expect(governor.set(false, client: app) == nil)
        #expect(!power.value)
    }

    /// The hold that leaves with the connection that took it: this is what
    /// makes a `mactoolsctl` killed mid-command safe.
    @Test("the only holder disconnecting lets this Mac sleep again at once")
    func theOnlyHolderLeavingClears() {
        let (governor, power, marker, client) = makeGovernor()
        governor.set(true, client: client)
        governor.clientLeft(token: client)
        #expect(!power.value)
        #expect(!marker.isMarked)
    }

    // MARK: - The guarantees

    @Test("a helper that starts on its own marker clears what the last run left")
    func recoversAtStart() {
        let (governor, power, marker, _) = makeGovernor(flag: true, marked: true)
        governor.recoverAtStart()
        #expect(!power.value)
        #expect(!marker.isMarked)
    }

    @Test("a helper that starts with no marker leaves a foreign flag alone")
    func recoveryLeavesAForeignFlag() {
        let (governor, power, _, _) = makeGovernor(flag: true, marked: false)
        governor.recoverAtStart()
        #expect(power.value)
        #expect(power.writes == 0)
    }

    @Test("the last client to leave lets this Mac sleep again")
    func lastClientClears() {
        let (governor, power, _, first) = makeGovernor()
        let second = governor.clientArrived()
        governor.set(true, client: first)
        governor.set(true, client: second)

        governor.clientLeft(token: first)
        #expect(power.value, "the second client is still holding it")

        governor.clientLeft(token: second)
        #expect(!power.value)
    }

    /// XPC can send both an interruption and an invalidation for one
    /// connection, so the same token arrives twice.
    @Test("a token that leaves twice only counts once")
    func aTokenLeavesOnce() {
        let (governor, power, _, first) = makeGovernor()
        let second = governor.clientArrived()
        governor.set(true, client: first)
        governor.set(true, client: second)
        governor.clientLeft(token: first)
        governor.clientLeft(token: first)
        #expect(power.value)
        governor.clientLeft(token: second)
        #expect(!power.value)
    }

    @Test("termination clears the flag, and only ours")
    func terminationClears() {
        let (governor, power, _, client) = makeGovernor()
        governor.set(true, client: client)
        governor.clearForTermination()
        #expect(!power.value)
        #expect(governor.holdCount == 0)

        let (other, foreign, _, _) = makeGovernor(flag: true)
        other.clearForTermination()
        #expect(foreign.value)
    }

    /// The governor is called from several XPC queues at once. A hold and a
    /// release that interleave inside one read-decide-write are how a flag is
    /// left set with nobody behind it, and one lock around the whole sequence
    /// is what stops it.
    @Test("holds and releases from many threads never leave the flag set")
    func concurrentHoldsAndReleasesSettleClear() async {
        let power = InMemorySleepSwitch()
        let marker = InMemorySleepDisabledMarker()
        let governor = SleepDisabledGovernor(power: power, marker: marker)
        let clients = (0..<8).map { _ in governor.clientArrived() }

        await withTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask {
                    for _ in 0..<50 {
                        governor.set(true, client: client)
                        governor.set(false, client: client)
                    }
                }
            }
        }

        #expect(governor.holdCount == 0)
        #expect(!power.value, "every hold was given back")
        #expect(!marker.isMarked)
    }

    // MARK: - The marker on disk

    @Test("the file marker appears, is seen and goes away again")
    func fileMarkerRoundTrip() throws {
        let directory = URL.temporaryDirectory.appending(path: "mactools-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let marker = FileSleepDisabledMarker(path: directory.appending(path: "sleep-disabled").path)
        #expect(!marker.isMarked)
        try marker.mark()
        #expect(marker.isMarked)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        // Marking twice is what a second hold does, and it is not an error.
        try marker.mark()
        #expect(marker.isMarked)

        try marker.unmark()
        #expect(!marker.isMarked)
        // Nor is removing one that is already gone.
        try marker.unmark()
        #expect(!marker.isMarked)
    }

    @Test("a marker that cannot be written says which path failed")
    func fileMarkerReportsItsPath() {
        let path = "/var/empty/no-such-directory-\(UUID().uuidString)/sleep-disabled"
        let marker = FileSleepDisabledMarker(path: path)
        #expect(!marker.isMarked)
        #expect(throws: SleepMarkerError.self) { try marker.mark() }
        #expect(!marker.isMarked)
    }

    /// The whole point of the real marker: the helper writes it, and a helper
    /// that starts on it clears the flag the last run left.
    @Test("a governor recovers from a marker file a previous run left on disk")
    func recoversFromAFileMarker() throws {
        let directory = URL.temporaryDirectory.appending(path: "mactools-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "sleep-disabled").path

        // The run that died: it marked and set, and then nothing cleared it.
        let died = SleepDisabledGovernor(
            power: InMemorySleepSwitch(),
            marker: FileSleepDisabledMarker(path: path)
        )
        died.set(true, client: died.clientArrived())

        // The next run, over a flag that survived the reboot.
        let power = InMemorySleepSwitch(disabled: true)
        let marker = FileSleepDisabledMarker(path: path)
        #expect(marker.isMarked)
        SleepDisabledGovernor(power: power, marker: marker).recoverAtStart()
        #expect(!power.value)
        #expect(!marker.isMarked)
    }

    // MARK: - The wire

    @Test("the report crosses the wire unchanged")
    func reportIsCodable() throws {
        for report in [
            SleepDisabledReport(isSet: true, setByMacTools: true),
            SleepDisabledReport(isSet: true, setByMacTools: false),
            SleepDisabledReport.clear,
        ] {
            let data = try JSONEncoder().encode(report)
            #expect(try JSONDecoder().decode(SleepDisabledReport.self, from: data) == report)
        }
    }

    @Test("an owner is one of three words, and they survive a round trip")
    func ownerIsCodable() throws {
        for owner in [SleepDisabledOwner.nobody, .macTools, .somebodyElse] {
            let data = try JSONEncoder().encode(owner)
            #expect(try JSONDecoder().decode(SleepDisabledOwner.self, from: data) == owner)
        }
    }

    @Test("the registry says when the last one is gone")
    func registryCounts() {
        var registry = SleepClientRegistry()
        #expect(registry.isEmpty)
        let first = registry.add(1)
        #expect(first, "the first client")
        let second = registry.add(2)
        #expect(!second)
        let afterFirstLeft = registry.remove(1)
        #expect(!afterFirstLeft)
        let afterSecondLeft = registry.remove(2)
        #expect(afterSecondLeft)
        #expect(registry.isEmpty)
        let again = registry.remove(2)
        #expect(!again, "a token that already left")
    }
}
