import Testing

import FanControl

/// Guarantee 1: the fans follow the last client out of the door.
@Test("the fans go back to Auto when the last client leaves")
func clientRegistryLastOut() {
    var registry = FanClientRegistry()
    #expect(registry.add(1) == true)
    #expect(registry.add(2) == false)
    #expect(registry.count == 2)

    #expect(registry.remove(1) == false)
    #expect(registry.remove(2) == true)
    #expect(registry.isEmpty)
}

/// XPC can report both an interruption and an invalidation for one connection,
/// and a token that left twice must not restore the fans twice.
@Test("an unknown or repeated departure changes nothing")
func clientRegistryIgnoresUnknownTokens() {
    var registry = FanClientRegistry()
    #expect(registry.remove(7) == false)
    registry.add(7)
    #expect(registry.remove(7) == true)
    #expect(registry.remove(7) == false)
    #expect(registry.add(7) == true)
}

@Test("a client that registers twice still only counts once")
func clientRegistryIsASet() {
    var registry = FanClientRegistry()
    #expect(registry.add(3) == true)
    #expect(registry.add(3) == false)
    #expect(registry.count == 1)
    #expect(registry.remove(3) == true)
}

@Test("sleep parks the fans and wake puts the modes back")
func powerPolicy() {
    var policy = FanPowerPolicy()
    #expect(policy.willSleep(hasDesiredMode: true) == .restoreAuto)
    // macOS can send the same message twice for one sleep.
    #expect(policy.willSleep(hasDesiredMode: true) == .nothing)
    #expect(policy.hasPoweredOn(hasDesiredMode: true) == .reapplyDesired)
    #expect(policy.willSleep(hasDesiredMode: true) == .restoreAuto)
}

@Test("a machine with every fan in Auto does nothing on sleep or wake")
func powerPolicyWithoutModes() {
    var policy = FanPowerPolicy()
    #expect(policy.willSleep(hasDesiredMode: false) == .nothing)
    #expect(policy.hasPoweredOn(hasDesiredMode: false) == .nothing)
    // A wake with no sleep before it, after a forced power cycle.
    #expect(policy.hasPoweredOn(hasDesiredMode: true) == .reapplyDesired)
}

@Test("a wake after a parked sleep reapplies even when the wish is gone")
func powerPolicyWishDroppedDuringSleep() {
    var policy = FanPowerPolicy()
    #expect(policy.willSleep(hasDesiredMode: true) == .restoreAuto)
    // A client set Auto during a dark wake. The governor still holds the
    // fans for the sleep, and only the reapply lifts that.
    #expect(policy.hasPoweredOn(hasDesiredMode: false) == .reapplyDesired)
    // The next wake of an idle machine is quiet again.
    #expect(policy.willSleep(hasDesiredMode: false) == .nothing)
    #expect(policy.hasPoweredOn(hasDesiredMode: false) == .nothing)
}

// MARK: - The Ftst unlock path

private final class UnlockFake: FanUnlockHardware, @unchecked Sendable {
    let hasForceTargets: Bool
    /// How many direct writes fail before one succeeds.
    var failuresLeft: Int
    private(set) var modeWrites = 0
    private(set) var forceWrites = 0

    init(hasForceTargets: Bool, failuresLeft: Int) {
        self.hasForceTargets = hasForceTargets
        self.failuresLeft = failuresLeft
    }

    func writeManualMode(fan index: Int) throws(FanHardwareError) {
        modeWrites += 1
        guard failuresLeft <= 0 else {
            failuresLeft -= 1
            throw FanHardwareError("the SMC refuses F\(index)Md")
        }
    }

    func writeForceTargets() throws(FanHardwareError) {
        forceWrites += 1
    }
}

@Test("a machine that takes the direct write never touches Ftst")
func unlockDirect() throws {
    let hardware = UnlockFake(hasForceTargets: true, failuresLeft: 0)
    try FanUnlockStrategy.enableManualMode(fan: 0, using: hardware) { _ in }
    #expect(hardware.modeWrites == 1)
    #expect(hardware.forceWrites == 0)
}

@Test("without Ftst a refused mode write is the end of it")
func unlockWithoutForceTargets() {
    let hardware = UnlockFake(hasForceTargets: false, failuresLeft: 10)
    #expect(throws: FanHardwareError.self) {
        try FanUnlockStrategy.enableManualMode(fan: 0, using: hardware) { _ in }
    }
    #expect(hardware.modeWrites == 1)
    #expect(hardware.forceWrites == 0)
}

@Test("with Ftst the mode write is retried until the machine agrees")
func unlockWithForceTargets() throws {
    let hardware = UnlockFake(hasForceTargets: true, failuresLeft: 3)
    var slept: Double = 0
    try FanUnlockStrategy.enableManualMode(fan: 0, using: hardware) { slept += $0 }
    #expect(hardware.forceWrites == 1)
    #expect(hardware.modeWrites == 4)
    // The first failure is the direct attempt, before the retry loop.
    #expect(slept == FanUnlockStrategy.retryIntervalSeconds * 2)
}

@Test("the retry window is not endless")
func unlockGivesUp() {
    let hardware = UnlockFake(hasForceTargets: true, failuresLeft: .max)
    var slept: Double = 0
    #expect(throws: FanHardwareError.self) {
        try FanUnlockStrategy.enableManualMode(fan: 0, using: hardware) { slept += $0 }
    }
    #expect(slept <= FanUnlockStrategy.retryWindowSeconds)
    #expect(hardware.modeWrites > 1)
}

@Test("Ftst is cleared only when the last forced fan is back in Auto")
func forceTargetsLatch() {
    var latch = ForceTargetsLatch()
    latch.forcing(fan: 0)
    latch.forcing(fan: 1)
    latch.forceTargetsWritten()
    #expect(latch.release(fan: 0) == false)
    #expect(latch.release(fan: 1) == true)
    latch.forceTargetsCleared()
    #expect(latch.isSet == false)

    // A machine that never needed Ftst never writes it.
    latch.forcing(fan: 0)
    #expect(latch.release(fan: 0) == false)

    // A clear that failed is tried again on the next fan back to Auto.
    latch.forcing(fan: 1)
    latch.forceTargetsWritten()
    #expect(latch.release(fan: 1) == true)
    #expect(latch.release(fan: 1) == true)
}
