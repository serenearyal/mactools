import Testing

@testable import SysMetrics

@Suite("disk I/O delta arithmetic")
struct DiskIOMathTests {
    private func counters(_ read: UInt64, _ written: UInt64, _ reads: UInt64 = 0, _ writes: UInt64 = 0) -> DiskIOCounters {
        DiskIOCounters(bytesRead: read, bytesWritten: written, reads: reads, writes: writes)
    }

    @Test("throughput is the delta over the interval")
    func throughput() throws {
        let rates = try #require(
            DiskIOMath.rates(
                from: counters(1_000, 2_000, 10, 20),
                to: counters(3_000, 8_000, 30, 120),
                seconds: 2
            )
        )
        #expect(rates.bytesReadPerSecond == 1_000)
        #expect(rates.bytesWrittenPerSecond == 3_000)
        #expect(rates.readsPerSecond == 10)
        #expect(rates.writesPerSecond == 50)
        #expect(rates.interval == 2)
    }

    @Test("a 1.5 GB write over one second reads back as 1.5 GB/s")
    func largeWrite() throws {
        let rates = try #require(
            DiskIOMath.rates(from: counters(0, 0), to: counters(0, 1_572_864_000), seconds: 1)
        )
        #expect(rates.bytesWrittenPerSecond == 1_572_864_000)
        #expect(rates.bytesReadPerSecond == 0)
    }

    @Test("a counter that went backwards contributes zero, never a negative rate")
    func counterReset() throws {
        #expect(DiskIOMath.delta(from: 5_000, to: 10) == 0)
        let rates = try #require(
            DiskIOMath.rates(from: counters(5_000, 5_000, 50, 50), to: counters(10, 6_000, 5, 60), seconds: 1)
        )
        #expect(rates.bytesReadPerSecond == 0)
        #expect(rates.readsPerSecond == 0)
        #expect(rates.bytesWrittenPerSecond == 1_000)
        #expect(rates.writesPerSecond == 10)
    }

    @Test("a non-positive or infinite interval has no rate")
    func badInterval() {
        #expect(DiskIOMath.rates(from: counters(0, 0), to: counters(1, 1), seconds: 0) == nil)
        #expect(DiskIOMath.rates(from: counters(0, 0), to: counters(1, 1), seconds: -1) == nil)
        #expect(DiskIOMath.rates(from: counters(0, 0), to: counters(1, 1), seconds: .infinity) == nil)
    }

    @Test("counters of several drivers add up")
    func summing() {
        let total = [counters(1, 2, 3, 4), counters(10, 20, 30, 40), .zero]
            .reduce(DiskIOCounters.zero, +)
        #expect(total == counters(11, 22, 33, 44))
    }

    @Test("an unchanged counter set gives a zero rate, not nil")
    func idleInterval() throws {
        let rates = try #require(
            DiskIOMath.rates(from: counters(7, 7, 7, 7), to: counters(7, 7, 7, 7), seconds: 1)
        )
        #expect(rates == DiskIORates(
            bytesReadPerSecond: 0,
            bytesWrittenPerSecond: 0,
            readsPerSecond: 0,
            writesPerSecond: 0,
            interval: 1
        ))
    }
}

@Suite("disk I/O per-device deltas")
struct DiskIODeviceMathTests {
    private func counters(_ read: UInt64, _ written: UInt64, _ reads: UInt64 = 0, _ writes: UInt64 = 0) -> DiskIOCounters {
        DiskIOCounters(bytesRead: read, bytesWritten: written, reads: reads, writes: writes)
    }

    @Test("an ejected disk does not hide the traffic of the internal one")
    func ejectKeepsInternalTraffic() throws {
        let before = ["disk0": counters(1_000, 1_000, 10, 10), "disk4": counters(9_000_000, 9_000_000, 900, 900)]
        let after = ["disk0": counters(3_000, 5_000, 30, 50)]
        let rates = try #require(DiskIOMath.rates(from: before, to: after, seconds: 2))
        #expect(rates.bytesReadPerSecond == 1_000)
        #expect(rates.bytesWrittenPerSecond == 2_000)
        #expect(rates.readsPerSecond == 10)
        #expect(rates.writesPerSecond == 20)
    }

    @Test("a disk that is new contributes nothing until it has a baseline")
    func newDeviceHasNoBaseline() {
        let before = ["disk0": counters(1_000, 1_000)]
        let after = ["disk0": counters(1_500, 1_000), "disk4": counters(8_000_000, 8_000_000, 80, 80)]
        #expect(DiskIOMath.traffic(from: before, to: after) == counters(500, 0))
    }

    @Test("a device whose counters went backwards contributes zero, the others still count")
    func resetDeviceContributesZero() {
        let before = ["disk0": counters(1_000, 1_000, 10, 10), "disk2": counters(5_000, 5_000, 50, 50)]
        let after = ["disk0": counters(2_000, 1_500, 20, 15), "disk2": counters(10, 10, 1, 1)]
        #expect(DiskIOMath.traffic(from: before, to: after) == counters(1_000, 500, 10, 5))
    }

    @Test("the live sampler has no rate on the first call and a finite one on the second")
    func liveSampler() throws {
        let sampler = DiskIOSampler()
        #expect(try sampler.sample().rates == nil)
        let rates = try #require(try sampler.sample().rates)
        #expect(rates.interval > 0)
        #expect(rates.bytesReadPerSecond.isFinite)
        #expect(rates.bytesWrittenPerSecond >= 0)
    }
}
