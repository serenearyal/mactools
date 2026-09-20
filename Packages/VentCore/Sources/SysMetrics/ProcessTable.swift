import Darwin
import Foundation

/// Which slice of the process table the user asked for.
public enum ProcessFilterScope: String, CaseIterable, Sendable, Identifiable {
    case all
    case mine
    case system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All processes"
        case .mine: "My processes"
        case .system: "System processes"
        }
    }
}

/// One line of the Processes table: the sampled row plus the login name its
/// uid resolves to, so filtering, searching and sorting stay pure.
public struct ProcessTableRow: Sendable, Equatable, Identifiable {
    public let info: ProcessInfoRow
    public let userName: String

    public init(info: ProcessInfoRow, userName: String) {
        self.info = info
        self.userName = userName
    }

    public var id: Int32 { info.pid }
    public var pid: Int32 { info.pid }
    public var uid: uid_t { info.uid }
    public var name: String { info.name }
    public var executablePath: String? { info.executablePath }
    public var cpuPercent: Double? { info.cpuPercent }
    public var memoryBytes: UInt64? { info.memoryBytes }
    public var isRestricted: Bool { info.isRestricted }
}

public enum ProcessSortKey: String, CaseIterable, Sendable {
    case name
    case pid
    case user
    case cpu
    case memory
}

/// A `SortComparator` for `Table`, so the column headers drive the same pure
/// ordering the tests check.
public struct ProcessComparator: SortComparator, Hashable, Sendable {
    public var key: ProcessSortKey
    public var order: SortOrder

    public init(key: ProcessSortKey, order: SortOrder = .forward) {
        self.key = key
        self.order = order
    }

    public func compare(_ lhs: ProcessTableRow, _ rhs: ProcessTableRow) -> ComparisonResult {
        ProcessTable.compare(lhs, rhs, by: key, ascending: order == .forward)
    }
}

/// What the Processes tab does to the sampled rows before it draws them.
///
/// All of it is pure: the tab keeps the sampled array as it comes and derives
/// the visible one, so a refresh in the middle of a drag changes no state the
/// user is holding.
public enum ProcessTable {
    // MARK: - Filtering

    public static func filter(
        _ rows: [ProcessTableRow],
        scope: ProcessFilterScope,
        currentUID: uid_t,
        query: String = ""
    ) -> [ProcessTableRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return rows.filter { row in
            inScope(row, scope: scope, currentUID: currentUID) && matches(row, query: trimmed)
        }
    }

    public static func inScope(
        _ row: ProcessTableRow,
        scope: ProcessFilterScope,
        currentUID: uid_t
    ) -> Bool {
        switch scope {
        case .all: true
        case .mine: row.uid == currentUID
        case .system: row.uid != currentUID
        }
    }

    /// Name, pid and executable path, case and diacritic insensitive. The pid
    /// matches on substring, so "58" finds both 58 and 1580: a user who types
    /// a pid from a log rarely has all of it.
    public static func matches(_ row: ProcessTableRow, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        if row.name.localizedCaseInsensitiveContains(trimmed) { return true }
        if String(row.pid).contains(trimmed) { return true }
        if let path = row.executablePath, path.localizedCaseInsensitiveContains(trimmed) { return true }
        return row.userName.localizedCaseInsensitiveContains(trimmed)
    }

    // MARK: - Ordering

    public static func sorted(
        _ rows: [ProcessTableRow],
        by key: ProcessSortKey,
        ascending: Bool
    ) -> [ProcessTableRow] {
        rows.sorted { compare($0, $1, by: key, ascending: ascending) == .orderedAscending }
    }

    /// A total order, so two refreshes of the same rows draw the same table:
    /// equal keys fall back to the pid, which no two live processes share.
    ///
    /// A row whose counter is unavailable sorts last in both directions. The
    /// alternative, treating nil as zero, would fill the top of an ascending
    /// CPU sort with the rows that say nothing.
    public static func compare(
        _ lhs: ProcessTableRow,
        _ rhs: ProcessTableRow,
        by key: ProcessSortKey,
        ascending: Bool
    ) -> ComparisonResult {
        let primary: ComparisonResult = switch key {
        case .name:
            directed(lhs.name.localizedStandardCompare(rhs.name), ascending)
        case .pid:
            directed(order(lhs.pid, rhs.pid), ascending)
        case .user:
            directed(userOrder(lhs, rhs), ascending)
        case .cpu:
            optionalOrder(lhs.cpuPercent, rhs.cpuPercent, ascending)
        case .memory:
            optionalOrder(lhs.memoryBytes, rhs.memoryBytes, ascending)
        }
        return primary == .orderedSame ? order(lhs.pid, rhs.pid) : primary
    }

    /// Names first, then the uid, so two accounts that share a name (or two
    /// uids with no name at all) still order the same way every time.
    private static func userOrder(_ lhs: ProcessTableRow, _ rhs: ProcessTableRow) -> ComparisonResult {
        let byName = lhs.userName.localizedStandardCompare(rhs.userName)
        return byName == .orderedSame ? order(lhs.uid, rhs.uid) : byName
    }

    private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private static func directed(_ result: ComparisonResult, _ ascending: Bool) -> ComparisonResult {
        guard !ascending else { return result }
        return switch result {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }

    private static func optionalOrder<T: Comparable>(_ lhs: T?, _ rhs: T?, _ ascending: Bool) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): .orderedSame
        case (nil, _): .orderedDescending
        case (_, nil): .orderedAscending
        case (let lhs?, let rhs?): directed(order(lhs, rhs), ascending)
        }
    }

    // MARK: - Totals

    /// The CPU the visible rows account for, in the same unit as a row: 100 %
    /// is one busy core.
    public static func totalCPUPercent(_ rows: [ProcessTableRow]) -> Double {
        rows.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
    }

    public static func restrictedCount(_ rows: [ProcessTableRow]) -> Int {
        rows.count { $0.isRestricted }
    }
}
