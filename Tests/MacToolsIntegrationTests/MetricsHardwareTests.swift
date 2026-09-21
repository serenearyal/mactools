import Darwin
import XCTest

import SysMetrics

/// Read-only checks of the metrics engine against the machine that runs the
/// tests. Nothing here writes, and every bound is loose enough to survive a
/// busy machine.
final class MetricsHardwareTests: XCTestCase {
    func testTheTopologyMatchesTheKernel() {
        let topology = CoreTopology.current()
        XCTAssertEqual(topology.logicalCount, Sysctl.integer("hw.logicalcpu"))
        XCTAssertEqual(topology.kinds.count, topology.logicalCount)
        XCTAssertEqual(
            topology.levels.reduce(0) { $0 + $1.logicalCount },
            topology.logicalCount,
            "the perflevel counts must add up to hw.logicalcpu"
        )
        XCTAssertGreaterThan(topology.performanceCount, 0)
    }

    func testTheSamplerReportsOneUsagePerLogicalCore() throws {
        let sampler = CPUSampler()
        XCTAssertNil(try sampler.sample(), "the first sample has no baseline to subtract")
        Thread.sleep(forTimeInterval: 0.5)
        let sample = try XCTUnwrap(try sampler.sample())

        XCTAssertEqual(sample.cores.count, Sysctl.integer("hw.logicalcpu"))
        XCTAssertEqual(sample.kinds.count, sample.cores.count)
        for (index, core) in sample.cores.enumerated() {
            XCTAssertTrue((0...1).contains(core.busy), "core \(index) busy \(core.busy)")
            XCTAssertTrue((0...1).contains(core.idle), "core \(index) idle \(core.idle)")
            XCTAssertEqual(core.user + core.system + core.idle + core.nice, 1, accuracy: 1e-9)
        }
        XCTAssertTrue((0...1).contains(sample.total.busy))
    }

    func testMemoryUsedIsPlausible() throws {
        let snapshot = try MemorySampler.sample()
        XCTAssertEqual(snapshot.total, Sysctl.uint64("hw.memsize"))
        XCTAssertGreaterThan(snapshot.used, 1_000_000_000, "less than 1 GB used is not a live machine")
        XCTAssertLessThan(snapshot.used, snapshot.total)
        XCTAssertEqual(snapshot.used, snapshot.app + snapshot.wired + snapshot.compressed)
        XCTAssertGreaterThan(snapshot.wired, 0)
        XCTAssertGreaterThanOrEqual(snapshot.swap.total, snapshot.swap.used)
        XCTAssertTrue(
            [4_096, 16_384].contains(MemorySampler.pageSize),
            "unexpected page size \(MemorySampler.pageSize)"
        )
    }

    func testTheBootVolumeIsListedWithItsContainerCapacity() throws {
        let volumes = DiskSpaceSampler.sample()
        XCTAssertFalse(volumes.isEmpty)
        let boot = try XCTUnwrap(volumes.first { $0.isBootVolume }, "no boot volume in \(volumes)")

        XCTAssertGreaterThan(boot.total, 100_000_000_000, "the boot volume reports \(boot.total) bytes")
        XCTAssertEqual(boot.mountPath, "/")
        XCTAssertEqual(boot.fileSystemType, "apfs")
        XCTAssertTrue(boot.isInternal)
        XCTAssertFalse(boot.isRemovable)
        XCTAssertEqual(boot.used, boot.total - boot.available)
        XCTAssertLessThan(boot.used, boot.total)
        XCTAssertTrue((0...1).contains(boot.usedFraction))
    }

    func testDiskIOCountersOnlyGoUp() throws {
        let sampler = DiskIOSampler()
        let first = try sampler.sample()
        XCTAssertNil(first.rates, "the first sample has no interval")
        XCTAssertFalse(first.devices.isEmpty, "no IOBlockStorageDriver in the registry")
        XCTAssertGreaterThan(first.total.bytesRead, 0)

        Thread.sleep(forTimeInterval: 0.3)
        let second = try sampler.sample()
        XCTAssertGreaterThanOrEqual(second.total.bytesRead, first.total.bytesRead)
        XCTAssertGreaterThanOrEqual(second.total.bytesWritten, first.total.bytesWritten)
        XCTAssertGreaterThanOrEqual(second.total.reads, first.total.reads)
        XCTAssertGreaterThanOrEqual(second.total.writes, first.total.writes)

        let rates = try XCTUnwrap(second.rates)
        XCTAssertGreaterThan(rates.interval, 0)
        XCTAssertGreaterThanOrEqual(rates.bytesReadPerSecond, 0)
        XCTAssertGreaterThanOrEqual(rates.bytesWrittenPerSecond, 0)
    }

    func testThisProcessAppearsInTheProcessTable() throws {
        let sampler = ProcessSampler()
        let rows = try sampler.sample()
        XCTAssertGreaterThan(rows.count, 20)

        let mine = try XCTUnwrap(rows.first { $0.pid == getpid() })
        XCTAssertNotNil(mine.memoryBytes, "this process must be able to read its own footprint")
        XCTAssertGreaterThan(mine.memoryBytes ?? 0, 1_000_000)
        XCTAssertNotNil(mine.startAbsoluteTime)
        XCTAssertNil(mine.cpuPercent, "the first sample of a process has no percent")
        XCTAssertEqual(mine.parentPID, getppid())
        XCTAssertFalse(mine.name.isEmpty)

        Thread.sleep(forTimeInterval: 0.3)
        let again = try XCTUnwrap(try sampler.sample().first { $0.pid == getpid() })
        let percent = try XCTUnwrap(again.cpuPercent, "the second sample must have a percent")
        XCTAssertGreaterThanOrEqual(percent, 0)
        XCTAssertLessThanOrEqual(
            percent,
            Double(CoreTopology.current().logicalCount) * 100 + 10
        )
    }

    func testLaunchdIsListedEvenThoughItsCountersAreRefused() throws {
        let rows = try ProcessSampler().sample()
        let launchd = try XCTUnwrap(rows.first { $0.pid == 1 }, "pid 1 is missing from the table")
        XCTAssertEqual(launchd.name, "launchd")
        XCTAssertEqual(launchd.uid, 0)
        // Without root the rusage call is refused, so nil is the expected
        // value here; the helper fills it in later.
        XCTAssertTrue(launchd.cpuPercent == nil || launchd.cpuPercent! >= 0)
        XCTAssertTrue(launchd.memoryBytes == nil || launchd.memoryBytes! > 0)
    }

    func testEveryPIDKeepsItsIdentityEvenWhenTheCountersAreRefused() throws {
        let rows = try ProcessSampler().sample()
        for row in rows where row.isRestricted {
            XCTAssertFalse(row.name.isEmpty, "pid \(row.pid) has no name")
            XCTAssertNil(row.cpuPercent, "pid \(row.pid) has a percent without a footprint")
        }
        XCTAssertTrue(rows.contains { $0.isRestricted }, "some root-owned process must refuse its counters")
    }
}
