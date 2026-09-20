import Foundation
import Testing

@testable import SysMetrics

@Suite("memory arithmetic")
struct MemoryMathTests {
    /// The page counts this machine reported while `vm_stat` was captured
    /// next to it: 16 GiB, 16 KB pages.
    private let pages = VMPageCounts(
        free: 11_869,
        active: 200_136,
        inactive: 193_545,
        speculative: 7_549,
        wired: 143_509,
        purgeable: 848,
        internalPages: 266_536,
        externalPages: 135_542,
        compressor: 452_465
    )
    private let pageSize: UInt64 = 16_384
    private let total: UInt64 = 17_179_869_184

    @Test("used is app plus wired plus compressed, the Activity Monitor definition")
    func usedMatchesActivityMonitor() {
        let snapshot = MemoryMath.snapshot(
            pages: pages,
            pageSize: pageSize,
            total: total,
            swap: SwapUsage(total: 1_073_741_824, used: 18_743_296),
            pressure: .warning
        )
        // app = (internal 266536 - purgeable 848) * 16384
        #expect(snapshot.app == 265_688 * 16_384)
        #expect(snapshot.wired == 143_509 * 16_384)
        #expect(snapshot.compressed == 452_465 * 16_384)
        #expect(snapshot.used == snapshot.app + snapshot.wired + snapshot.compressed)
        #expect(snapshot.cachedFiles == (135_542 + 848) * 16_384)
        #expect(snapshot.free == 11_869 * 16_384)
        #expect(snapshot.total == total)
        #expect(snapshot.used < snapshot.total)
        #expect(snapshot.swap.used == 18_743_296)
        #expect(snapshot.pressure == .warning)
    }

    @Test("the used fraction is the share of the installed memory")
    func usedFraction() {
        let snapshot = MemoryMath.snapshot(
            pages: pages, pageSize: pageSize, total: total, swap: .none, pressure: nil
        )
        #expect(abs(snapshot.usedFraction - Double(snapshot.used) / Double(total)) < 1e-12)
        #expect((0...1).contains(snapshot.usedFraction))
    }

    @Test("a 4 KB page machine scales the same counts down")
    func intelPageSize() {
        let small = MemoryMath.snapshot(
            pages: pages, pageSize: 4_096, total: total, swap: .none, pressure: nil
        )
        let large = MemoryMath.snapshot(
            pages: pages, pageSize: 16_384, total: total, swap: .none, pressure: nil
        )
        #expect(large.used == small.used * 4)
    }

    @Test("more purgeable pages than anonymous pages cannot make app memory negative")
    func purgeableOverflow() {
        let odd = VMPageCounts(purgeable: 100, internalPages: 10, externalPages: 5, compressor: 1)
        let snapshot = MemoryMath.snapshot(
            pages: odd, pageSize: 16_384, total: total, swap: .none, pressure: nil
        )
        #expect(snapshot.app == 0)
        #expect(snapshot.used == 16_384)
    }

    @Test("an empty machine reports nothing used")
    func zeroed() {
        let snapshot = MemoryMath.snapshot(
            pages: VMPageCounts(), pageSize: 16_384, total: 0, swap: .none, pressure: nil
        )
        #expect(snapshot.used == 0)
        #expect(snapshot.usedFraction == 0)
    }

    @Test("the pressure sysctl values map to the documented levels")
    func pressureLevels() {
        #expect(MemoryPressureLevel(rawValue: 1) == .normal)
        #expect(MemoryPressureLevel(rawValue: 2) == .warning)
        #expect(MemoryPressureLevel(rawValue: 4) == .critical)
        #expect(MemoryPressureLevel(rawValue: 3) == nil)
        #expect(MemoryPressureLevel.critical.label == "critical")
    }

    @Test("a snapshot round-trips through Codable for the XPC payloads")
    func codable() throws {
        let snapshot = MemoryMath.snapshot(
            pages: pages, pageSize: pageSize, total: total, swap: .none, pressure: .normal
        )
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(MemorySnapshot.self, from: data) == snapshot)
    }
}
