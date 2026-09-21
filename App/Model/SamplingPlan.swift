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

/// What the power system is doing, as the cadence rules see it.
///
/// Every field arrives by push - `IOPSNotificationCreateRunLoopSource`,
/// `NSProcessInfoPowerStateDidChange` and `thermalStateDidChange` - so reading
/// this costs nothing and nothing polls for it.
struct PowerConditions: Equatable, Sendable {
    var onBattery = false
    var lowPowerMode = false
    var thermalState: ProcessInfo.ThermalState = .nominal

    /// Serious or critical: the machine is already struggling, and a monitor
    /// is the last thing that should be adding to it.
    var isThermallyStressed: Bool {
        thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }
}

/// What the app is showing right now: who wants numbers, which tab of the
/// window they are looking at, and whether the menu bar label is drawing a
/// number at all.
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
    /// False for "Show in menu bar: icon only", and for a status item that is
    /// not on any screen - the menu bar of a notched Mac runs out of room and
    /// the system parks the item off the edge.
    ///
    /// The label is the only consumer that is always there, so this is what
    /// lets the app fall all the way to zero: with it false and nothing else
    /// on screen, no pass is run at all.
    var menuBarShowsMetrics = true

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
        if names.isEmpty { return menuBarShowsMetrics ? "menu bar only" : "nothing on screen" }
        return names.joined(separator: " + ") + (menuBarShowsMetrics ? "" : " (label off)")
    }
}

/// The one place that decides what each store reads and how often.
///
/// Pure by design: the stores hold the state and the timers, these rules are
/// values in and values out, so the awkward part can be tested.
enum SamplingPlan {
    /// Everything the Dashboard section draws: CPU, memory, the boot volume
    /// and its throughput, the CPU and GPU dies behind "hottest CPU" and
    /// "GPU", the fans and `PSTR`.
    ///
    /// Not the labelled set: the section draws two temperatures, and the
    /// labelled set is three times the driver round trips for the SSD, the
    /// battery and the enclosure sensors that live on the Sensors tab.
    static let popoverRequest = SampleRequest(
        cpu: true,
        memory: true,
        diskSpace: true,
        diskIO: true,
        temperatures: .cpuGPU,
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
    /// However slow the power rules make it, a number on screen is never more
    /// than this old.
    static let maximumInterval = Duration.seconds(10)
    /// Activity Monitor's own default for the process table.
    static let processInterval = Duration.seconds(3)
    /// The popover shows three rows per column, not a table.
    static let popoverProcessInterval = Duration.seconds(5)
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
        // A label that draws no number asks for nothing at all, not even the
        // one CPU call: that is what lets an icon-only app, and an app whose
        // status item the menu bar has no room for, sample nothing.
        var request = demand.menuBarShowsMetrics
            ? menuBarRequest(metrics: menuBarMetrics, chosenSensorScope: chosenSensorScope)
            : .nothing
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
        showsUnlabelledSensors: Bool = false,
        conditions: PowerConditions = PowerConditions()
    ) -> Duration {
        let base = baseInterval(
            demand: demand,
            refreshSeconds: refreshSeconds,
            menuBarMetrics: menuBarMetrics,
            showsUnlabelledSensors: showsUnlabelledSensors
        )
        var scaled = base * powerFactor(demand: demand, conditions: conditions)
        // A Mac at serious thermal state is already in trouble; a monitor is
        // the last thing that should be waking its cores up.
        if conditions.isThermallyStressed { scaled = Swift.max(scaled, idleInterval) }
        return Swift.min(scaled, maximumInterval)
    }

    /// What the cadence would be on wall power, with a cool machine.
    private static func baseInterval(
        demand: SamplingDemand,
        refreshSeconds: Double,
        menuBarMetrics: [MenuBarMetric],
        showsUnlabelledSensors: Bool
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
        return menuBarMetrics.isEmpty || !demand.menuBarShowsMetrics
            ? idleInterval
            : .seconds(refreshSeconds)
    }

    /// Slower on a battery nobody is watching, slower again in Low Power Mode.
    ///
    /// The battery rule only applies with nothing on screen: a user who has
    /// the window open is watching the numbers, and halving their refresh rate
    /// to save a few milliwatts is the wrong trade. Low Power Mode is the user
    /// asking for exactly that trade, so it counts on screen too. On wall
    /// power it only halves the cadence: some Macs run Low Power Mode all the
    /// time, and a menu bar label that moves every eight seconds looks stuck.
    static func powerFactor(demand: SamplingDemand, conditions: PowerConditions) -> Int {
        if conditions.lowPowerMode { return conditions.onBattery ? 4 : 2 }
        if conditions.onBattery, demand.consumers.isEmpty { return 2 }
        return 1
    }

    /// The shortest time between two temperature reads.
    ///
    /// A die does not move in a second, and every sensor is a driver round
    /// trip: the profiler puts the SMC reads at the top of what an open
    /// popover costs. So a pass that comes round sooner than this skips the
    /// temperatures and keeps the ones it has.
    static let temperatureFloor = Duration.seconds(3)

    /// True when this pass should leave the temperatures alone.
    ///
    /// The two tabs that graph sensors are the exception: somebody who is
    /// watching a sensor chart asked for every point of it.
    static func throttlesTemperatures(demand: SamplingDemand, sinceLastRead: Duration) -> Bool {
        guard !demand.showsTab(.sensors), !demand.showsTab(.fans) else { return false }
        return sinceLastRead < temperatureFloor
    }

    /// A fifth of the interval, on every periodic sleep in the app.
    ///
    /// The kernel may fire a tolerant timer early or late to put it next to a
    /// wakeup it was making anyway. One second of slack on a five second pass
    /// costs nobody anything on screen and it is what keeps a sleeping core
    /// asleep.
    static func tolerance(for interval: Duration) -> Duration { interval / 5 }

    /// When the "Awake 42m" badge must be redrawn next.
    ///
    /// The text only ever changes on a minute boundary, so the timer aims at
    /// the boundary instead of ticking once a second - and in the last minute,
    /// where the text is the fixed "under 1m", it is a slow heartbeat that
    /// only guards against clock drift. The expiry itself has its own timer.
    static func badgeTick(remainingSeconds: Int) -> Duration {
        guard remainingSeconds > 60 else { return .seconds(15) }
        let toBoundary = remainingSeconds % 60
        return .seconds(toBoundary == 0 ? 60 : toBoundary)
    }

    /// True when a pass would read at least one counter.
    ///
    /// False is the whole point of the icon-only and hidden-item rules: the
    /// store runs no loop at all, so an app with nothing on screen and no
    /// number in the menu bar costs exactly one sleeping thread.
    static func samplesMetrics(
        demand: SamplingDemand,
        menuBarMetrics: [MenuBarMetric],
        chosenSensorScope: TemperatureScope = .labelled,
        showsUnlabelledSensors: Bool = false
    ) -> Bool {
        !metricsRequest(
            demand: demand,
            menuBarMetrics: menuBarMetrics,
            chosenSensorScope: chosenSensorScope,
            showsUnlabelledSensors: showsUnlabelledSensors
        ).readsNothing
    }

    /// The process table costs one libproc round trip per process, so it only
    /// runs for somebody who is looking at it: its own tab, or the Dashboard
    /// section of the popover.
    static func samplesProcesses(_ demand: SamplingDemand) -> Bool {
        demand.showsTab(.processes) || demand.showsPopoverSection(.dashboard)
    }

    /// How often that pass runs.
    ///
    /// One pass is a libproc round trip for each of about 580 processes, and
    /// the profiler says it is the most expensive thing an open popover does.
    /// The table on its own tab is worth Activity Monitor's three seconds; the
    /// three rows per column in the popover are a glance, and five is plenty
    /// for them.
    static func processInterval(_ demand: SamplingDemand) -> Duration {
        demand.showsTab(.processes) ? processInterval : popoverProcessInterval
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
