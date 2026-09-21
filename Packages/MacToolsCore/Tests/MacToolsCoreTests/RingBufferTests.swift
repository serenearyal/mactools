import Testing

@testable import SysMetrics

@Suite("ring buffer")
struct RingBufferTests {
    @Test("a fresh buffer is empty and knows its capacity")
    func empty() {
        let buffer = RingBuffer<Int>(capacity: 4)
        #expect(buffer.isEmpty)
        #expect(buffer.count == 0)
        #expect(buffer.capacity == 4)
        #expect(!buffer.isFull)
        #expect(buffer.elements == [])
    }

    @Test("appends below the capacity stay in order")
    func belowCapacity() {
        var buffer = RingBuffer<Int>(capacity: 5)
        for value in 1...3 { buffer.append(value) }
        #expect(buffer.elements == [1, 2, 3])
        #expect(buffer.first == 1)
        #expect(buffer.last == 3)
        #expect(!buffer.isFull)
    }

    @Test("the buffer is full at exactly the capacity")
    func exactlyFull() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...3 { buffer.append(value) }
        #expect(buffer.isFull)
        #expect(buffer.elements == [1, 2, 3])
    }

    @Test("appending past the capacity drops the oldest element")
    func wraparound() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...4 { buffer.append(value) }
        #expect(buffer.elements == [2, 3, 4])
        buffer.append(5)
        #expect(buffer.elements == [3, 4, 5])
        #expect(buffer.count == 3)
    }

    @Test("many laps around the buffer keep the order oldest to newest")
    func manyLaps() {
        var buffer = RingBuffer<Int>(capacity: 7)
        for value in 1...100 { buffer.append(value) }
        #expect(buffer.elements == Array(94...100))
        #expect(buffer.first == 94)
        #expect(buffer.last == 100)
        // Subscripting agrees with the iteration order after every wrap.
        #expect((0..<buffer.count).map { buffer[$0] } == buffer.elements)
    }

    @Test("a capacity of one keeps the newest element only")
    func capacityOne() {
        var buffer = RingBuffer<String>(capacity: 1)
        buffer.append("a")
        buffer.append("b")
        #expect(buffer.elements == ["b"])
    }

    @Test("removeAll empties the buffer and resets the wrap position")
    func removeAll() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.append(value) }
        buffer.removeAll()
        #expect(buffer.isEmpty)
        buffer.append(9)
        #expect(buffer.elements == [9])
    }

    @Test("the buffer is a value type: a copy does not see later appends")
    func valueSemantics() {
        var buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(1)
        let copy = buffer
        buffer.append(2)
        #expect(copy.elements == [1])
        #expect(buffer.elements == [1, 2])
    }

    @Test("two buffers with the same contents and capacity are equal")
    func equality() {
        var left = RingBuffer<Int>(capacity: 3)
        var right = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { left.append(value) }
        for value in 3...5 { right.append(value) }
        #expect(left == right)
        right.append(6)
        #expect(left != right)
        var wider = RingBuffer<Int>(capacity: 9)
        for value in 3...5 { wider.append(value) }
        #expect(left != wider)
    }

    @Test("collection algorithms work on the buffer")
    func collectionConformance() {
        var buffer = RingBuffer<Double>(capacity: 4)
        for value in [1.0, 2.0, 3.0, 4.0, 5.0] { buffer.append(value) }
        #expect(buffer.reduce(0, +) == 14)
        #expect(buffer.max() == 5)
        #expect(Array(buffer.suffix(2)) == [4, 5])
    }
}
