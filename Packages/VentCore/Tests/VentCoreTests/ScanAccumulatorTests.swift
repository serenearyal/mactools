import Foundation
import Testing

@testable import ScanKit

private func file(_ path: String, _ allocated: UInt64, logical: UInt64? = nil) -> WalkedFile {
    WalkedFile(
        path: path,
        allocated: allocated,
        logical: logical ?? allocated,
        modified: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Suite("scan accumulator")
struct ScanAccumulatorTests {
    @Test("the ranking keeps the largest files, biggest first")
    func ranking() {
        var accumulator = ScanAccumulator(limit: 2, homeDirectory: "/Users/x")
        accumulator.add(file("/Users/x/small", 1_000))
        accumulator.add(file("/Users/x/huge", 9_000_000))
        accumulator.add(file("/Users/x/medium", 500_000))

        #expect(accumulator.entries.map(\.path) == ["/Users/x/huge", "/Users/x/medium"])
        #expect(accumulator.entries.first?.allocated == 9_000_000)
    }

    @Test("the breakdown buckets the root and the home folder separately")
    func breakdown() throws {
        var accumulator = ScanAccumulator(limit: 10, homeDirectory: "/Users/x")
        accumulator.add(file("/Users/x/Library/Caches/a", 300))
        accumulator.add(file("/Users/x/Library/Caches/b", 700))
        accumulator.add(file("/Users/x/Movies/c.mov", 5_000))
        accumulator.add(file("/Applications/Xcode.app/x", 20_000))
        accumulator.add(file("/private/var/vm/swapfile0", 1_000))
        accumulator.add(file("/Users/y/other", 42))

        let home = accumulator.homeFolders
        #expect(home.map(\.path) == ["/Users/x/Movies", "/Users/x/Library"])
        #expect(home.map(\.name) == ["Movies", "Library"])
        #expect(home.first?.allocated == 5_000)
        #expect(try #require(home.last).allocated == 1_000)
        #expect(try #require(home.last).files == 2)

        let root = accumulator.rootFolders
        #expect(root.map(\.path) == ["/Applications", "/Users/x", "/private/var", "/Users/y"])
        #expect(root.first?.allocated == 20_000)
    }

    @Test("a file loose in the home folder counts against the home folder")
    func looseHomeFile() {
        var accumulator = ScanAccumulator(limit: 4, homeDirectory: "/Users/x")
        accumulator.add(file("/Users/x/notes.txt", 4_096))
        #expect(accumulator.homeFolders.map(\.path) == ["/Users/x"])
    }

    @Test("the accumulator takes the display form of the home directory")
    func homeIsMapped() {
        var accumulator = ScanAccumulator(
            limit: 4,
            homeDirectory: "/System/Volumes/Data/Users/x"
        )
        accumulator.add(file("/Users/x/Movies/c.mov", 5_000))
        #expect(accumulator.homeFolders.map(\.path) == ["/Users/x/Movies"])
    }

    @Test("a sparse file keeps both sizes")
    func sparseFile() throws {
        var accumulator = ScanAccumulator(limit: 4, homeDirectory: "/Users/x")
        accumulator.add(file("/Users/x/sparse.img", 4_096, logical: 10_000_000_000))
        let entry = try #require(accumulator.entries.first)
        #expect(entry.allocated == 4_096)
        #expect(entry.logical == 10_000_000_000)
        #expect(entry.name == "sparse.img")
        #expect(entry.parentPath == "/Users/x")
    }
}

@Suite("progress throttle")
struct ProgressThrottleTests {
    /// `#expect` cannot call a mutating member, so every gate check goes
    /// through a plain call first.
    private func gate(_ throttle: inout ProgressThrottle, _ times: [Double]) -> [Bool] {
        times.map { throttle.shouldEmit(at: $0) }
    }

    @Test("at most one event per interval")
    func tenHertz() {
        var throttle = ProgressThrottle(interval: 0.1, start: 0)
        #expect(gate(&throttle, [0.05, 0.1, 0.15, 0.2]) == [false, true, false, true])
    }

    @Test("a long gap emits once, not once per missed interval")
    func longGap() {
        var throttle = ProgressThrottle(interval: 0.1, start: 0)
        #expect(gate(&throttle, [5, 5.01, 5.11]) == [true, false, true])
    }

    @Test("a clock that goes backwards does not open the gate")
    func backwardsClock() {
        var throttle = ProgressThrottle(interval: 0.1, start: 100)
        #expect(gate(&throttle, [99, 100.2]) == [false, true])
    }

    @Test("about ten ticks per second, never more")
    func rateOverASecond() {
        var throttle = ProgressThrottle(interval: Scan.progressInterval, start: 0)
        // 1024 calls over one second. The gate opens 10 times, or 9 when the
        // binary value of 0.1 pushes the last one past the end of the second.
        let emitted = (1...1_024).count { throttle.shouldEmit(at: Double($0) / 1_024) }
        #expect((9...10).contains(emitted))
    }
}
