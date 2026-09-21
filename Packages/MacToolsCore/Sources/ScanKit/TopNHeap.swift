/// The `capacity` largest elements of a stream, by a caller-supplied key.
///
/// A min-heap over a `ContiguousArray`: the smallest kept element sits at the
/// root, so a candidate only has to beat that one. Insert is O(log capacity)
/// and the storage never grows past `capacity`, which is what lets a scan of
/// 4.4 M files hold 500 entries of memory instead of 4.4 M.
public struct TopNHeap<Element> {
    public let capacity: Int

    private var storage: ContiguousArray<Element>
    private let key: (Element) -> UInt64

    public init(capacity: Int, key: @escaping (Element) -> UInt64) {
        self.capacity = max(0, capacity)
        self.key = key
        storage = []
        storage.reserveCapacity(self.capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var isFull: Bool { storage.count == capacity }

    /// The key a candidate has to beat once the heap is full, nil while it
    /// still has room.
    public var threshold: UInt64? { isFull ? storage.first.map(key) : nil }

    public mutating func insert(_ element: Element) {
        guard capacity > 0 else { return }
        guard isFull else {
            storage.append(element)
            siftUp(from: storage.count - 1)
            return
        }
        // Equal keys keep the incumbent, so a long run of same-size files
        // does not churn the heap.
        guard key(element) > key(storage[0]) else { return }
        storage[0] = element
        siftDown(from: 0)
    }

    /// Largest first. Elements with equal keys keep no defined order.
    public func sortedDescending() -> [Element] {
        storage.sorted { key($0) > key($1) }
    }

    private mutating func siftUp(from start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard key(storage[child]) < key(storage[parent]) else { return }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var smallest = parent
            if left < storage.count, key(storage[left]) < key(storage[smallest]) {
                smallest = left
            }
            if right < storage.count, key(storage[right]) < key(storage[smallest]) {
                smallest = right
            }
            guard smallest != parent else { return }
            storage.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
