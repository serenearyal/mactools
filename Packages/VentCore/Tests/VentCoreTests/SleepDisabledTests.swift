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
    private func makeGovernor(
        flag: Bool = false,
        marked: Bool = false
    ) -> (SleepDisabledGovernor, InMemorySleepSwitch, InMemorySleepDisabledMarker) {
        let power = InMemorySleepSwitch(disabled: flag)
        let marker = InMemorySleepDisabledMarker(marked: marked)
        return (SleepDisabledGovernor(power: power, marker: marker), power, marker)
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
        let (governor, power, marker) = makeGovernor()
        #expect(governor.set(true) == nil)
        #expect(power.value)
        #expect(power.writes == 1)
        #expect(marker.isMarked)
        #expect(governor.report() == SleepDisabledReport(isSet: true, setByVent: true))
        #expect(governor.report()?.owner == .vent)

        // Asking again changes nothing at all.
        #expect(governor.set(true) == nil)
        #expect(power.writes == 1)
    }

    @Test("clearing the flag writes it back and gives up ownership")
    func clearsWhatItSet() {
        let (governor, power, marker) = makeGovernor()
        governor.set(true)
        #expect(governor.set(false) == nil)
        #expect(!power.value)
        #expect(power.writes == 2)
        #expect(!marker.isMarked)
        #expect(governor.report()?.owner == .nobody)
    }

    @Test("a flag pmset set is reported, refused and never touched")
    func refusesAForeignFlag() {
        let (governor, power, marker) = makeGovernor(flag: true)
        #expect(governor.report() == SleepDisabledReport(isSet: true, setByVent: false))
        #expect(governor.report()?.owner == .somebodyElse)

        #expect(governor.set(true) == SleepDisabledPolicy.foreignMessage)
        #expect(governor.set(false) == SleepDisabledPolicy.foreignMessage)
        #expect(power.value, "the user's own setting is still there")
        #expect(power.writes == 0)
        #expect(!marker.isMarked)
    }

    /// The dangerous order: Vent sets the flag, the user runs `pmset` to clear
    /// it, and the marker is now a lie. Nothing may be written because of it.
    @Test("a marker with no flag behind it is dropped, not acted on")
    func staleMarkerIsDropped() {
        let (governor, power, marker) = makeGovernor()
        governor.set(true)
        power.setExternally(false)

        #expect(governor.set(false) == nil)
        #expect(power.writes == 1, "there was nothing left to clear")
        #expect(!marker.isMarked)
    }

    @Test("a power manager that refuses says so and owns nothing")
    func aRefusedWriteIsReported() {
        let power = InMemorySleepSwitch(failure: "not permitted")
        let marker = InMemorySleepDisabledMarker()
        let governor = SleepDisabledGovernor(power: power, marker: marker)
        let failure = governor.set(true)
        #expect(failure?.contains("not permitted") == true)
        #expect(!marker.isMarked)
        #expect(governor.report() == nil)
    }

    // MARK: - The guarantees

    @Test("a helper that starts on its own marker clears what the last run left")
    func recoversAtStart() {
        let (governor, power, marker) = makeGovernor(flag: true, marked: true)
        governor.recoverAtStart()
        #expect(!power.value)
        #expect(!marker.isMarked)
    }

    @Test("a helper that starts with no marker leaves a foreign flag alone")
    func recoveryLeavesAForeignFlag() {
        let (governor, power, _) = makeGovernor(flag: true, marked: false)
        governor.recoverAtStart()
        #expect(power.value)
        #expect(power.writes == 0)
    }

    @Test("the last client to leave lets this Mac sleep again")
    func lastClientClears() {
        let (governor, power, _) = makeGovernor()
        let first = governor.clientArrived()
        let second = governor.clientArrived()
        governor.set(true)

        governor.clientLeft(token: first)
        #expect(power.value, "somebody is still connected")

        governor.clientLeft(token: second)
        #expect(!power.value)
    }

    /// XPC can send both an interruption and an invalidation for one
    /// connection, so the same token arrives twice.
    @Test("a token that leaves twice only counts once")
    func aTokenLeavesOnce() {
        let (governor, power, _) = makeGovernor()
        let first = governor.clientArrived()
        let second = governor.clientArrived()
        governor.set(true)
        governor.clientLeft(token: first)
        governor.clientLeft(token: first)
        #expect(power.value)
        governor.clientLeft(token: second)
        #expect(!power.value)
    }

    @Test("termination clears the flag, and only ours")
    func terminationClears() {
        let (governor, power, _) = makeGovernor()
        governor.set(true)
        governor.clearForTermination()
        #expect(!power.value)

        let (other, foreign, _) = makeGovernor(flag: true)
        other.clearForTermination()
        #expect(foreign.value)
    }

    // MARK: - The wire

    @Test("the report crosses the wire unchanged")
    func reportIsCodable() throws {
        for report in [
            SleepDisabledReport(isSet: true, setByVent: true),
            SleepDisabledReport(isSet: true, setByVent: false),
            SleepDisabledReport.clear,
        ] {
            let data = try JSONEncoder().encode(report)
            #expect(try JSONDecoder().decode(SleepDisabledReport.self, from: data) == report)
        }
    }

    @Test("an owner is one of three words, and they survive a round trip")
    func ownerIsCodable() throws {
        for owner in [SleepDisabledOwner.nobody, .vent, .somebodyElse] {
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
