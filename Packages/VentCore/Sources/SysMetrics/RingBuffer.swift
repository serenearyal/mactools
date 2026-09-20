/// Fixed-capacity buffer for metric history. Appending past the capacity drops
/// the oldest element. Iteration is always oldest to newest, so a graph can
/// read it straight through.
public struct RingBuffer<Element> {
    public let capacity: Int

    private var storage: [Element]
    /// Position of the oldest element inside `storage`. Zero until the buffer
    /// is full, because before that `storage` is already in order.
    private var head: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "a ring buffer needs room for at least one element")
        self.capacity = capacity
        storage = []
        storage.reserveCapacity(capacity)
        head = 0
    }

    public var isFull: Bool { storage.count == capacity }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    /// The contents oldest to newest, as a plain array.
    public var elements: [Element] { Array(self) }
}

extension RingBuffer: RandomAccessCollection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { storage.count }

    public subscript(position: Int) -> Element {
        precondition(position >= 0 && position < storage.count, "index out of range")
        return storage[(head + position) % capacity]
    }
}

extension RingBuffer: Sendable where Element: Sendable {}
extension RingBuffer: Equatable where Element: Equatable {
    public static func == (lhs: RingBuffer, rhs: RingBuffer) -> Bool {
        lhs.capacity == rhs.capacity && lhs.elementsEqual(rhs)
    }
}
