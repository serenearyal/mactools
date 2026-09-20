import Foundation

/// Who is asking the stores for live numbers.
///
/// The menu bar label is not a member: it is always there, and it is what the
/// stores fall back to when this set is empty.
struct SamplingConsumers: OptionSet, Sendable, Hashable {
    let rawValue: Int

    /// The main window, showing `SamplingDemand.activeTab`.
    static let window = SamplingConsumers(rawValue: 1 << 0)
    /// The menu bar popover.
    static let popover = SamplingConsumers(rawValue: 1 << 1)
}

/// What the app is showing right now: who wants numbers, and which tab of the
/// window they are looking at.
///
/// One value, published by `AppServices` to all three stores, so the cadence
/// of the app has a single source of truth instead of one private rule per
/// store.
struct SamplingDemand: Equatable, Sendable {
    var consumers: SamplingConsumers = []
    var activeTab: MainTab = .overview
    /// The window is on screen but another window covers it completely.
    ///
    /// It is not the same as hidden: the user can bring it back with one
    /// click, and it must show the history of the minutes it was covered
    /// rather than a gap. So it slows the sampling down and nothing else.
    var windowOccluded = false

    var wantsWindow: Bool { consumers.contains(.window) }
    var wantsPopover: Bool { consumers.contains(.popover) }

    /// True only for a tab that is really on screen: a selected tab inside a
    /// hidden window is nobody looking.
    func showsTab(_ tab: MainTab) -> Bool { wantsWindow && activeTab == tab }

    /// One line for the log, so a sampling leak can be read back afterwards.
    var summary: String {
        var names: [String] = []
        if wantsWindow { names.append("window(\(activeTab.rawValue))\(windowOccluded ? " covered" : "")") }
        if wantsPopover { names.append("popover") }
        return names.isEmpty ? "menu bar only" : names.joined(separator: " + ")
    }
}

/// The one place that decides what each store reads and how often.
///
/// Pure by design: the stores hold the state and the timers, these rules are
/// values in and values out, so the awkward part can be tested.
enum SamplingPlan {
    /// Everything the popover draws: CPU, memory, the boot volume and its
    /// throughput, the labelled temperatures behind "hottest CPU" and "GPU",
    /// the fans and `PSTR`.
    static let popoverRequest = SampleRequest(
        cpu: true,
        memory: true,
        diskSpace: true,
        diskIO: true,
        temperatures: .labelled,
        fans: true,
        power: .system
    )

    /// 5 s, for an app whose menu bar label shows no number at all.
    static let idleInterval = Duration.seconds(5)
    /// Activity Monitor's own default for the process table.
    static let processInterval = Duration.seconds(3)
    /// One fan snapshot is one SMC read in the helper.
    static let fanInterval = Duration.seconds(2)

    /// What one pass must read to satisfy every consumer at once.
    ///
    /// With nothing on screen this is the menu bar request and nothing else,
    /// which is what an idle app costs.
    static func metricsRequest(
        demand: SamplingDemand,
        menuBarMetrics: [MenuBarMetric],
        chosenSensorScope: TemperatureScope,
        showsUnlabelledSensors: Bool
    ) -> SampleRequest {
        var request = menuBarRequest(
            metrics: menuBarMetrics,
            chosenSensorScope: chosenSensorScope
        )
        if demand.wantsPopover {
            request.formUnion(popoverRequest)
        }
        if demand.wantsWindow {
            var window = SampleRequest.everything
            if demand.activeTab == .sensors, showsUnlabelledSensors {
                window.temperatures = .everything
            }
            request.formUnion(window)
        }
        return request
    }

    /// Only what the menu bar label shows. CPU stays on either way: one mach
    /// call, and it keeps the history graph continuous.
    static func menuBarRequest(
        metrics: [MenuBarMetric],
        chosenSensorScope: TemperatureScope
    ) -> SampleRequest {
        var request = SampleRequest()
        for metric in metrics {
            switch metric {
            case .cpuUsage:
                request.cpu = true
            case .memoryUsed, .memoryPercent:
                request.memory = true
            case .diskUsedPercent, .diskFree:
                request.diskSpace = true
            case .diskIO:
                request.diskIO = true
            case .cpuTemperature:
                request.temperatures = max(request.temperatures, .cpu)
            case .sensorTemperature:
                request.temperatures = max(request.temperatures, chosenSensorScope)
            case .fanSpeed:
                request.fans = true
            case .systemPower:
                request.power = max(request.power, .system)
            }
        }
        return request
    }

    /// The user's refresh interval while anything is on screen, 5 s for an
    /// idle app whose label shows nothing and for a window nobody can see.
    ///
    /// A covered window keeps its full request, so the graphs stay continuous
    /// and nothing is cleared; only the cadence drops.
    static func metricsInterval(
        demand: SamplingDemand,
        refreshSeconds: Double,
        menuBarMetrics: [MenuBarMetric]
    ) -> Duration {
        if demand.wantsPopover { return .seconds(refreshSeconds) }
        if demand.wantsWindow {
            return demand.windowOccluded ? idleInterval : .seconds(refreshSeconds)
        }
        return menuBarMetrics.isEmpty ? idleInterval : .seconds(refreshSeconds)
    }

    /// The process table costs one libproc round trip per process, so it only
    /// runs for somebody who is looking at it.
    static func samplesProcesses(_ demand: SamplingDemand) -> Bool {
        demand.showsTab(.processes) || demand.wantsPopover
    }

    /// Fan snapshots go through the helper over XPC; the same rule applies.
    static func pollsFans(_ demand: SamplingDemand) -> Bool {
        demand.showsTab(.fans) || demand.wantsPopover
    }
}

extension SampleRequest {
    /// The superset of two requests: what one pass must read to satisfy both.
    mutating func formUnion(_ other: SampleRequest) {
        cpu = cpu || other.cpu
        memory = memory || other.memory
        diskSpace = diskSpace || other.diskSpace
        diskIO = diskIO || other.diskIO
        temperatures = Swift.max(temperatures, other.temperatures)
        fans = fans || other.fans
        power = Swift.max(power, other.power)
    }

    func union(_ other: SampleRequest) -> SampleRequest {
        var copy = self
        copy.formUnion(other)
        return copy
    }
}
