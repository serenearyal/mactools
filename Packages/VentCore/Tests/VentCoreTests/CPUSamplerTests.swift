import Testing

@testable import SysMetrics

@Suite("CPU tick arithmetic")
struct CPUTickMathTests {
    private func ticks(_ user: UInt32, _ system: UInt32, _ idle: UInt32, _ nice: UInt32 = 0) -> CPUTicks {
        CPUTicks(user: user, system: system, idle: idle, nice: nice)
    }

    @Test("shares of one interval add up to one")
    func sharesAddUp() throws {
        let usage = try #require(
            CPUTickMath.usage(from: ticks(100, 50, 850), to: ticks(120, 60, 1_010, 10))
        )
        // deltas: user 20, system 10, idle 160, nice 10, total 200
        #expect(usage.user == 0.1)
        #expect(usage.system == 0.05)
        #expect(usage.idle == 0.8)
        #expect(usage.nice == 0.05)
        #expect(abs(usage.busy - 0.2) < 1e-12)
        #expect(abs(usage.percent - 20) < 1e-9)
    }

    @Test("a fully busy core reads 100 percent")
    func fullyBusy() throws {
        let usage = try #require(CPUTickMath.usage(from: ticks(0, 0, 0), to: ticks(90, 10, 0)))
        #expect(usage.busy == 1)
        #expect(usage.idle == 0)
    }

    @Test("an idle core reads zero")
    func idle() throws {
        let usage = try #require(CPUTickMath.usage(from: ticks(5, 5, 5), to: ticks(5, 5, 105)))
        #expect(usage.busy == 0)
        #expect(usage.idle == 1)
    }

    @Test("no tick movement has no usage to report")
    func noMovement() {
        #expect(CPUTickMath.usage(from: ticks(7, 8, 9), to: ticks(7, 8, 9)) == nil)
    }

    @Test("the 32-bit counters wrap without producing a jump")
    func counterWrap() throws {
        let previous = ticks(0xFFFF_FFF0, 0xFFFF_FFFF, 0xFFFF_FF00)
        let current = ticks(0x0000_0004, 0x0000_0009, 0x0000_0063)
        // deltas across the wrap: user 20, system 10, idle 355
        #expect(CPUTickMath.delta(from: previous.user, to: current.user) == 20)
        #expect(CPUTickMath.delta(from: previous.system, to: current.system) == 10)
        #expect(CPUTickMath.delta(from: previous.idle, to: current.idle) == 355)

        let usage = try #require(CPUTickMath.usage(from: previous, to: current))
        #expect(abs(usage.busy - 30.0 / 385.0) < 1e-12)
        #expect(usage.user + usage.system + usage.idle + usage.nice == 1)
    }

    @Test("a wrap of every counter at once still totals one")
    func wrapEverywhere() throws {
        let previous = ticks(.max, .max, .max, .max)
        let usage = try #require(CPUTickMath.usage(from: previous, to: ticks(24, 24, 49, 24)))
        #expect(abs(usage.user - 0.2) < 1e-12)
        #expect(abs(usage.idle - 0.4) < 1e-12)
    }

    @Test("a synthetic tick sequence tracks a ramp")
    func tickSequence() throws {
        // 100 ticks per second per core: idle, half busy, fully busy.
        var previous = ticks(1_000, 2_000, 3_000)
        let steps: [(CPUTicks, Double)] = [
            (ticks(1_000, 2_000, 3_100), 0),
            (ticks(1_040, 2_010, 3_150), 0.5),
            (ticks(1_140, 2_010, 3_150), 1),
        ]
        for (current, expected) in steps {
            let usage = try #require(CPUTickMath.usage(from: previous, to: current))
            #expect(abs(usage.busy - expected) < 1e-12, "step to \(current)")
            previous = current
        }
    }

    @Test("the machine total weighs every core the same")
    func totalOverCores() throws {
        let previous = [ticks(0, 0, 0), ticks(0, 0, 0)]
        // Core 0 fully busy for 100 ticks, core 1 fully idle for 100 ticks.
        let current = [ticks(100, 0, 0), ticks(0, 0, 100)]
        let result = try #require(CPUTickMath.usage(from: previous, to: current))
        #expect(result.cores[0].busy == 1)
        #expect(result.cores[1].busy == 0)
        #expect(result.total.busy == 0.5)
    }

    @Test("a core that reports nothing counts as idle, not as a hole")
    func stalledCore() throws {
        let result = try #require(
            CPUTickMath.usage(from: [ticks(0, 0, 0), ticks(5, 5, 5)], to: [ticks(50, 0, 50), ticks(5, 5, 5)])
        )
        #expect(result.cores.count == 2)
        #expect(result.cores[1] == .idleOnly)
        #expect(result.total.busy == 0.5)
    }

    @Test("readings of different core counts are not comparable")
    func mismatchedCoreCounts() {
        #expect(CPUTickMath.usage(from: [ticks(0, 0, 0)], to: [ticks(1, 1, 1), ticks(1, 1, 1)]) == nil)
        #expect(CPUTickMath.usage(from: [], to: []) == nil)
        #expect(CPUTickMath.usage(from: [ticks(1, 1, 1)], to: [ticks(1, 1, 1)]) == nil)
    }
}

@Suite("core topology")
struct CoreTopologyTests {
    @Test("the kernel numbers the efficiency cores before the performance cores")
    func indexOrder() {
        // Verified on this MacBookPro18,3: busy threads at .background QoS
        // land on indices 0 and 1, threads at .userInteractive on 2 to 7.
        let levels = [
            CoreLevel(index: 0, name: "Performance", logicalCount: 6, physicalCount: 6, kind: .performance),
            CoreLevel(index: 1, name: "Efficiency", logicalCount: 2, physicalCount: 2, kind: .efficiency),
        ]
        let kinds = CoreTopology.kinds(forLevelsHighestFirst: levels)
        #expect(kinds == [.efficiency, .efficiency] + Array(repeating: CoreKind.performance, count: 6))
    }

    @Test("a machine with one cluster is all performance")
    func singleLevel() {
        let levels = [
            CoreLevel(index: 0, name: "Performance", logicalCount: 8, physicalCount: 4, kind: .performance)
        ]
        #expect(CoreTopology.kinds(forLevelsHighestFirst: levels).allSatisfy { $0 == .performance })
    }

    @Test("the kind of an index outside the range falls back to performance")
    func outOfRange() {
        let topology = CoreTopology(logicalCount: 2, levels: [], kinds: [.efficiency, .performance])
        #expect(topology.kind(ofCore: 0) == .efficiency)
        #expect(topology.kind(ofCore: 1) == .performance)
        #expect(topology.kind(ofCore: 99) == .performance)
        #expect(topology.efficiencyCount == 1)
        #expect(topology.performanceCount == 1)
    }

    @Test("the tags are the letters the UI prints")
    func tags() {
        #expect(CoreKind.performance.tag == "P")
        #expect(CoreKind.efficiency.tag == "E")
    }
}
