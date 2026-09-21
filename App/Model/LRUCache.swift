import Foundation

/// A cache that forgets what has not been asked for in the longest time.
///
/// The menu bar label is what it was written for: the same handful of rendered
/// images come back all day - a placeholder, a temperature that sits still, an
/// idle percentage - and a plain dictionary of them would grow for every value
/// the machine ever showed and never give a byte back.
///
/// Values, no locks, no AppKit: it belongs to whoever holds it, and the tests
/// hold one of their own. The order is an array because the capacity is a
/// handful of entries, where a linked list is more code than it saves.
struct LRUCache<Key: Hashable, Value> {
    /// How many entries it keeps. The oldest one goes when a new entry does
    /// not fit.
    let capacity: Int

    private var storage: [Key: Value] = [:]
    /// Least recently used first, most recently used last.
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
        order.reserveCapacity(self.capacity)
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }
    /// Least recently used first. The tests read it; nothing else needs it.
    var keysByAge: [Key] { order }

    /// Reading counts as a use, which is what makes it an LRU and not a FIFO.
    mutating func value(forKey key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ value: Value, forKey key: Key) {
        if storage.updateValue(value, forKey: key) != nil {
            touch(key)
            return
        }
        order.append(key)
        while order.count > capacity {
            let evicted = order.removeFirst()
            storage.removeValue(forKey: evicted)
        }
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    private mutating func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else {
            order.append(key)
            return
        }
        guard index != order.count - 1 else { return }
        order.remove(at: index)
        order.append(key)
    }
}
