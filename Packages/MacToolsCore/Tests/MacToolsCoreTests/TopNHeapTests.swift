import Testing

@testable import ScanKit

/// Deterministic randomness: a failing case has to be reproducible.
private struct Xorshift: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x2545_F491_4F6C_DD1D : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

@Suite("bounded top-N heap")
struct TopNHeapTests {
    @Test("100k random sizes give the same ranking as a full sort")
    func matchesBruteForce() {
        var generator = Xorshift(seed: 0x5EED)
        let sizes = (0..<100_000).map { _ in UInt64.random(in: 0...(1 << 40), using: &generator) }

        var heap = TopNHeap<UInt64>(capacity: 500) { $0 }
        for size in sizes { heap.insert(size) }

        let expected = Array(sizes.sorted(by: >).prefix(500))
        #expect(heap.sortedDescending() == expected)
    }

    @Test("the storage never grows past the capacity")
    func capacityHolds() {
        var heap = TopNHeap<UInt64>(capacity: 8) { $0 }
        for value in (0..<5_000).map(UInt64.init) {
            heap.insert(value)
            #expect(heap.count <= 8)
        }
        #expect(heap.count == 8)
        #expect(heap.sortedDescending() == [4_999, 4_998, 4_997, 4_996, 4_995, 4_994, 4_993, 4_992])
    }

    @Test("duplicates all count, and the ranking keeps them")
    func duplicates() {
        var heap = TopNHeap<UInt64>(capacity: 3) { $0 }
        for value in [UInt64](repeating: 42, count: 10) { heap.insert(value) }
        #expect(heap.count == 3)
        #expect(heap.sortedDescending() == [42, 42, 42])

        heap.insert(43)
        #expect(heap.sortedDescending() == [43, 42, 42])
    }

    @Test("capacity 0 keeps nothing, capacity 1 keeps the maximum")
    func degenerateCapacities() {
        var empty = TopNHeap<UInt64>(capacity: 0) { $0 }
        for value in (0..<100).map(UInt64.init) { empty.insert(value) }
        #expect(empty.count == 0)
        #expect(empty.sortedDescending().isEmpty)
        #expect(empty.threshold == nil)

        var single = TopNHeap<UInt64>(capacity: 1) { $0 }
        for value in [7, 3, 99, 12, 99, 0].map(UInt64.init) { single.insert(value) }
        #expect(single.sortedDescending() == [99])
    }

    @Test("a negative capacity is treated as zero, not as a crash")
    func negativeCapacity() {
        var heap = TopNHeap<UInt64>(capacity: -5) { $0 }
        heap.insert(1)
        #expect(heap.capacity == 0)
        #expect(heap.count == 0)
    }

    @Test("the threshold is the smallest kept key, and only once full")
    func threshold() {
        var heap = TopNHeap<UInt64>(capacity: 3) { $0 }
        heap.insert(10)
        #expect(heap.threshold == nil)
        heap.insert(30)
        heap.insert(20)
        #expect(heap.threshold == 10)
        heap.insert(25)
        #expect(heap.threshold == 20)
    }

    @Test("the key can be any field of the element")
    func customKey() {
        struct File { let name: String; let size: UInt64 }
        var heap = TopNHeap<File>(capacity: 2) { $0.size }
        for file in [File(name: "a", size: 5), File(name: "b", size: 50), File(name: "c", size: 500)] {
            heap.insert(file)
        }
        #expect(heap.sortedDescending().map(\.name) == ["c", "b"])
    }
}
