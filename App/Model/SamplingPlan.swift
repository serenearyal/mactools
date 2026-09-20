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
    /// Which section of the popover is on screen. Only read while the popover
    /// is a consumer.
    var popoverSection: PopoverSection = .dashboard
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

    /// The same rule for the popover: a remembered section with the popover
    /// closed is nobody looking either.
    func showsPopoverSection(_ section: PopoverSection) -> Bool {
        wantsPopover && popoverSection == section
    }

    /// One line for the log, so a sampling leak can be read back afterwards.
    var summary: String {
        var names: [String] = []
        if wantsWindow { names.append("window(\(activeTab.rawValue))\(windowOccluded ? " covered" : "")") }
        if wantsPopover { names.append("popover(\(popoverSection.rawValue))") }
        return names.isEmpty ? "menu bar only" : names.joined(separator: " + ")
    }
}

/// The one place that decides what each store reads and how often.
///
/// Pure by design: the stores hold the state and the timers, these rules are
/// values in and values out, so the awkward part can be tested.
enum SamplingPlan {
    /// Everything the Dashboard section draws: CPU, memory, the boot volume
    /// and its throughput, the labelled temperatures behind "hottest CPU" and
    /// "GPU", the fans and `PSTR`.
    static let popoverRequest = SampleRequest(
        cpu: true,
        memory: true,
        diskSpace: true,
        diskIO: true,
        temperatures: .labelled,
        fans: true,
        power: .system
    )

    /// What one popover section shows, and nothing more.
    ///
    /// Tools draws one fan line; Windows draws no live number at all, so an
    /// open popover on that section costs what a closed one costs.
    static func popoverRequest(section: PopoverSection) -> SampleRequest {
        switch section {
        case .dashboard: popoverRequest
        case .windows: .nothing
        case .tools: SampleRequest(cpu: false, fans: true)
        }
    }

    /// What one tab of the window shows, and nothing more.
    ///
    /// Only the CPU history is kept continuous across tabs, and the menu bar
    /// request does that on its own: `SampleRequest()` always reads the CPU,
    /// which is one `host_processor_info` call. Sensor, power and disk history
    /// gap while their tab is off screen, which is what the graphs on those
    /// tabs already show when the window has just been opened.
    static func windowRequest(tab: MainTab, showsUnlabelledSensors: Bool) -> SampleRequest {
        switch tab {
        case .overview:
            // Everything the cards draw. Not `.everything`: the Overview shows
            // `PSTR` alone, the rail list is on Sensors.
            SampleRequest(
                cpu: true,
                memory: true,
                diskSpace: true,
                diskIO: true,
                temperatures: .labelled,
                fans: true,
                power: .system
            )
        case .sensors:
            SampleRequest(
                cpu: false,
                temperatures: showsUnlabelledSensors ? .everything : .labelled,
                power: .labelled
            )
        case .fans:
            SampleRequest(cpu: false, temperatures: .labelled, fans: true)
        case .storage:
            SampleRequest(cpu: false, diskSpace: true, diskIO: true)
        // The process table comes from `ProcessStore`, not from a metrics
        // pass, and the five tabs after it show no live number at all.
        case .processes, .windows, .keepAwake, .keyboardLock, .backlight, .settings:
            .nothing
        }
    }

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
            request.formUnion(popoverRequest(section: demand.popoverSection))
        }
        if demand.wantsWindow {
            request.formUnion(
                windowRequest(
                    tab: demand.activeTab,
                    showsUnlabelledSensors: showsUnlabelledSensors
                )
            )
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

    /// The user's refresh interval while a live number is on screen, 5 s for
    /// an idle app whose label shows nothing and for a window nobody can see.
    ///
    /// A tab or a popover section that draws no live number does not raise the
    /// cadence: the Windows tab in front of a menu bar label that shows
    /// nothing costs the idle 5 s pass, not the user's 1 s.
    ///
    /// A covered window keeps its full request, so the graphs stay continuous
    /// and nothing is cleared; only the cadence drops.
    static func metricsInterval(
        demand: SamplingDemand,
        refreshSeconds: Double,
        menuBarMetrics: [MenuBarMetric],
        showsUnlabelledSensors: Bool = false
    ) -> Duration {
        if demand.wantsPopover, !popoverRequest(section: demand.popoverSection).readsNothing {
            return .seconds(refreshSeconds)
        }
        let window = demand.wantsWindow
            ? windowRequest(tab: demand.activeTab, showsUnlabelledSensors: showsUnlabelledSensors)
            : .nothing
        if !window.readsNothing {
            return demand.windowOccluded ? idleInterval : .seconds(refreshSeconds)
        }
        return menuBarMetrics.isEmpty ? idleInterval : .seconds(refreshSeconds)
    }

    /// The process table costs one libproc round trip per process, so it only
    /// runs for somebody who is looking at it: its own tab, or the Dashboard
    /// section of the popover.
    static func samplesProcesses(_ demand: SamplingDemand) -> Bool {
        demand.showsTab(.processes) || demand.showsPopoverSection(.dashboard)
    }

    /// Fan snapshots go through the helper over XPC; the same rule applies,
    /// and the popover sections that show a fan are the ones that ask.
    static func pollsFans(_ demand: SamplingDemand) -> Bool {
        if demand.showsTab(.fans) { return true }
        return demand.wantsPopover && popoverRequest(section: demand.popoverSection).fans
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
