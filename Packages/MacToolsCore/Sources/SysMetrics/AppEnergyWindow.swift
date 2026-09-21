import Foundation

/// One process's energy counter at one instant.
///
/// `ri_energy_nj` counts up from the moment the process started, so a figure
/// for a window is the difference of two readings. The start time comes with it
/// because a pid the kernel has handed to another process carries a counter
/// that has nothing to do with the old one.
public struct ProcessEnergySample: Sendable, Equatable {
    public let energyNanojoules: UInt64
    public let startAbsoluteTime: UInt64?

    public init(energyNanojoules: UInt64, startAbsoluteTime: UInt64?) {
        self.energyNanojoules = energyNanojoules
        self.startAbsoluteTime = startAbsoluteTime
    }
}

public enum ProcessEnergyMath {
    /// The nanojoules one process burned between two readings.
    ///
    /// Zero, never a negative, for every case where the two readings are not
    /// comparable: no previous reading, a reused pid (the start time moved),
    /// and a counter that went backwards.
    public static func delta(previous: ProcessEnergySample?, current: ProcessEnergySample) -> UInt64 {
        guard let previous else { return 0 }
        guard previous.startAbsoluteTime == current.startAbsoluteTime else { return 0 }
        guard current.energyNanojoules > previous.energyNanojoules else { return 0 }
        return current.energyNanojoules - previous.energyNanojoules
    }
}

/// A rolling window of per-app CPU energy, about five minutes long.
///
/// The counters are cumulative, so one pass of the process table is a baseline
/// and every pass after it adds one slice: the joules each app burned since the
/// pass before, and how long that took. The mean power of an app is its joules
/// over the seconds the window covers.
///
/// Bounded by design: a slice holds one number per app rather than one per
/// process, old slices fall off the front by time and by count, and a pid that
/// is gone keeps nothing behind.
public struct AppEnergyWindow: Sendable {
    /// What one pass contributed.
    struct Slice: Sendable, Equatable {
        let date: Date
        let seconds: Double
        var apps: [AppIdentity: AppSlice]
    }

    struct AppSlice: Sendable, Equatable {
        var joules: Double
        var processCount: Int
    }

    /// Five minutes, which is the window the caption names.
    public static let defaultWindowSeconds: Double = 300
    /// Two passes closer together than this are not a slice: the popover and
    /// the tab can both ask, and a share of a tenth of a second is noise. The
    /// reading is dropped whole, baseline and all, so the next slice covers
    /// both intervals and no energy is lost.
    public static let minimumIntervalSeconds: Double = 0.5
    /// At the 3 s cadence of the Processes tab, 5 minutes is 100 slices. The
    /// cap is what holds the memory down if something ever samples faster.
    static let maximumSlices = 400

    public let windowSeconds: Double

    private var slices: [Slice] = []
    private var baselines: [Int32: ProcessEnergySample] = [:]
    private var lastDate: Date?

    public init(windowSeconds: Double = AppEnergyWindow.defaultWindowSeconds) {
        self.windowSeconds = max(1, windowSeconds)
    }

    /// How long the mean covers: the caption "last 5 min" is this, rounded.
    ///
    /// The sum of the slices rather than the span between the first and the
    /// last, so a window with a gap in the middle - the tab was off screen -
    /// reports the time it really measured.
    public var coveredSeconds: Double {
        slices.reduce(0) { $0 + $1.seconds }
    }

    /// True until two passes have landed, which is what the UI waits for.
    public var isEmpty: Bool { slices.isEmpty }

    /// One pass of the process table.
    ///
    /// A row whose counter is unreadable drops its baseline instead of keeping
    /// it: a process the helper answered for in one pass and not in the next
    /// would otherwise hand its whole gap to the pass where it came back, as
    /// one spike.
    public mutating func add(_ rows: [ProcessInfoRow], at date: Date = .now) {
        let seconds = lastDate.map { date.timeIntervalSince($0) } ?? 0
        // A clock that moved backwards, or two passes in the same instant.
        if lastDate != nil, seconds < AppEnergyWindow.minimumIntervalSeconds { return }

        var apps: [AppIdentity: AppSlice] = [:]
        apps.reserveCapacity(64)
        var next: [Int32: ProcessEnergySample] = [:]
        next.reserveCapacity(rows.count)

        for row in rows {
            let identity = AppGrouping.identity(
                executablePath: row.executablePath,
                processName: row.name
            )
            var slice = apps[identity] ?? AppSlice(joules: 0, processCount: 0)
            slice.processCount += 1
            guard let energy = row.energyNanojoules else {
                // No baseline for it either: see the note above.
                apps[identity] = slice
                continue
            }
            let current = ProcessEnergySample(
                energyNanojoules: energy,
                startAbsoluteTime: row.startAbsoluteTime
            )
            next[row.pid] = current
            let delta = ProcessEnergyMath.delta(previous: baselines[row.pid], current: current)
            slice.joules += Double(delta) / 1e9
            apps[identity] = slice
        }

        // Replacing the whole map is what evicts a pid that is gone; it
        // contributes nothing, and it cannot contribute a negative.
        baselines = next
        defer { lastDate = date }
        // The first pass is a baseline and nothing else.
        guard lastDate != nil else { return }
        // A pass after a long gap - the tab was off screen for an hour - is a
        // real amount of energy over a time the window cannot represent, and
        // averaging it in would make one number stand for the hour. The
        // baselines are kept, so the next slice is honest again.
        guard seconds <= windowSeconds else {
            slices.removeAll()
            return
        }
        slices.append(Slice(date: date, seconds: seconds, apps: apps))
        trim(now: date)
    }

    /// Drops the slices the window has moved past.
    private mutating func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        if let keep = slices.firstIndex(where: { $0.date > cutoff }) {
            if keep > 0 { slices.removeFirst(keep) }
        } else {
            slices.removeAll()
        }
        if slices.count > AppEnergyWindow.maximumSlices {
            slices.removeFirst(slices.count - AppEnergyWindow.maximumSlices)
        }
    }

    /// The heaviest apps of the window, most watts first.
    ///
    /// Empty until two passes have landed: one pass is a baseline with nothing
    /// to subtract from, and a list made from it would be all zeros.
    ///
    /// The shares are of every app the window saw, so the ten rows of the UI
    /// sum to less than 1 exactly when something outside them burned energy.
    public func topApps(limit: Int = 10) -> [AppEnergy] {
        guard limit > 0 else { return [] }
        let covered = coveredSeconds
        guard covered > 0 else { return [] }

        var joules: [AppIdentity: Double] = [:]
        var counts: [AppIdentity: Int] = [:]
        for slice in slices {
            for (identity, app) in slice.apps {
                joules[identity, default: 0] += app.joules
                // The newest slice that saw the app wins, so a browser that
                // just closed twenty tabs reports the twenty it has now.
                counts[identity] = app.processCount
            }
        }
        let total = joules.values.reduce(0, +)
        guard total > 0 else { return [] }

        let apps = joules.compactMap { identity, value -> AppEnergy? in
            guard value > 0 else { return nil }
            return AppEnergy(
                id: identity.id,
                name: identity.name,
                bundlePath: identity.bundlePath,
                watts: value / covered,
                share: value / total,
                processCount: counts[identity] ?? 0
            )
        }
        return Array(apps.sorted(by: AppEnergyWindow.heaviestFirst).prefix(limit))
    }

    /// Watts down, then name, then id: a dictionary hands its pairs over in no
    /// order at all, so two apps that burned the same energy have to be put in
    /// an order of their own or the list would shuffle on every pass.
    static func heaviestFirst(_ lhs: AppEnergy, _ rhs: AppEnergy) -> Bool {
        if lhs.watts != rhs.watts { return lhs.watts > rhs.watts }
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhs.id < rhs.id
    }

    /// Forgets the window and the baselines both.
    public mutating func reset() {
        slices.removeAll()
        baselines.removeAll()
        lastDate = nil
    }
}
