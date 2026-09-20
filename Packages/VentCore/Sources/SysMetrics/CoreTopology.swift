import Darwin

public enum CoreKind: String, Sendable, Codable, Equatable {
    case performance
    case efficiency

    /// One-letter tag for dense output ("P" / "E").
    public var tag: String { self == .performance ? "P" : "E" }
}

/// One `hw.perflevelN` cluster.
public struct CoreLevel: Sendable, Equatable {
    public let index: Int
    public let name: String
    public let logicalCount: Int
    public let physicalCount: Int
    public let kind: CoreKind

    public init(index: Int, name: String, logicalCount: Int, physicalCount: Int, kind: CoreKind) {
        self.index = index
        self.name = name
        self.logicalCount = logicalCount
        self.physicalCount = physicalCount
        self.kind = kind
    }
}

/// The CPU clusters of the machine and the kind of every `host_processor_info`
/// index.
public struct CoreTopology: Sendable, Equatable {
    public let logicalCount: Int
    /// Clusters in `hw.perflevelN` order, so level 0 is the fastest.
    public let levels: [CoreLevel]
    /// Kind of each core, indexed the way `host_processor_info` indexes cores.
    public let kinds: [CoreKind]

    public init(logicalCount: Int, levels: [CoreLevel], kinds: [CoreKind]) {
        self.logicalCount = logicalCount
        self.levels = levels
        self.kinds = kinds
    }

    public var performanceCount: Int { kinds.count { $0 == .performance } }
    public var efficiencyCount: Int { kinds.count { $0 == .efficiency } }

    public func kind(ofCore index: Int) -> CoreKind {
        kinds.indices.contains(index) ? kinds[index] : .performance
    }

    /// Core kinds in `host_processor_info` index order.
    ///
    /// The kernel numbers processors from the slowest cluster to the fastest,
    /// that is `hw.perflevel<last>` first and `hw.perflevel0` last. Verified on
    /// this MacBookPro18,3 (6 Performance + 2 Efficiency): two busy threads at
    /// `.background` QoS pin indices 0 and 1 at 100 % and leave the rest near
    /// idle, while six threads at `.userInteractive` QoS pin indices 2 to 7 at
    /// 100 % and leave 0 and 1 near idle. `powermetrics` needs a password on
    /// this machine, so the QoS experiment is the evidence.
    public static func kinds(forLevelsHighestFirst levels: [CoreLevel]) -> [CoreKind] {
        levels.sorted { $0.index > $1.index }
            .flatMap { level in Array(repeating: level.kind, count: level.logicalCount) }
    }

    /// Reads the topology from `hw.*`. Machines without `hw.nperflevels`
    /// (Intel) get one performance cluster.
    public static func current() -> CoreTopology {
        let logicalCount = Sysctl.integer("hw.logicalcpu") ?? 1
        let levelCount = Sysctl.integer("hw.nperflevels") ?? 0
        guard levelCount > 1 else {
            return CoreTopology(
                logicalCount: logicalCount,
                levels: [
                    CoreLevel(
                        index: 0,
                        name: Sysctl.string("hw.perflevel0.name") ?? "Performance",
                        logicalCount: logicalCount,
                        physicalCount: Sysctl.integer("hw.physicalcpu") ?? logicalCount,
                        kind: .performance
                    )
                ],
                kinds: Array(repeating: .performance, count: logicalCount)
            )
        }

        let levels = (0..<levelCount).map { index in
            CoreLevel(
                index: index,
                name: Sysctl.string("hw.perflevel\(index).name") ?? "Level \(index)",
                logicalCount: Sysctl.integer("hw.perflevel\(index).logicalcpu") ?? 0,
                physicalCount: Sysctl.integer("hw.perflevel\(index).physicalcpu") ?? 0,
                // Level 0 is the fastest cluster; every slower one is efficiency.
                kind: index == 0 ? .performance : .efficiency
            )
        }
        var kinds = kinds(forLevelsHighestFirst: levels)
        // Defensive: keep `kinds` and the processor count in step if a future
        // machine reports clusters that do not add up.
        if kinds.count != logicalCount {
            kinds = Array(
                (kinds + Array(repeating: CoreKind.performance, count: logicalCount)).prefix(logicalCount)
            )
        }
        return CoreTopology(logicalCount: logicalCount, levels: levels, kinds: kinds)
    }
}
