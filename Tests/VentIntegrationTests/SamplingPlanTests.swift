import Foundation
import SysMetrics
import Testing

/// The rules that decide what the app samples and how often. Pure values in,
/// pure values out, so every consumer combination is cheap to check.
///
/// The source files under test are compiled into this bundle (see
/// `project.yml`), so the app and the tests share one copy of the rules.
@Suite("Sampling plan")
struct SamplingPlanTests {
    private let menuBar: [MenuBarMetric] = [.cpuUsage, .cpuTemperature]

    private func request(
        _ demand: SamplingDemand,
        metrics: [MenuBarMetric]? = nil,
        unlabelled: Bool = false
    ) -> SampleRequest {
        SamplingPlan.metricsRequest(
            demand: demand,
            menuBarMetrics: metrics ?? menuBar,
            chosenSensorScope: .labelled,
            showsUnlabelledSensors: unlabelled
        )
    }

    // MARK: - What one pass reads

    @Test("Nothing on screen reads only what the menu bar label shows")
    func idleRequest() {
        let plan = request(SamplingDemand())
        #expect(plan.cpu)
        #expect(plan.temperatures == .cpu)
        #expect(!plan.memory)
        #expect(!plan.diskSpace)
        #expect(!plan.diskIO)
        #expect(!plan.fans)
        #expect(plan.power == .none)
    }

    @Test("An empty label still samples the CPU, and nothing else")
    func emptyLabelRequest() {
        let plan = request(SamplingDemand(), metrics: [])
        #expect(plan == SampleRequest())
    }

    @Test("The popover reads everything it draws")
    func popoverRequest() {
        let plan = request(SamplingDemand(consumers: .popover))
        #expect(plan.cpu)
        #expect(plan.memory)
        #expect(plan.diskSpace)
        #expect(plan.diskIO)
        #expect(plan.fans)
        // The two dies it draws, not the labelled set: the SSD, the battery
        // and the enclosure sensors belong to the Sensors tab.
        #expect(plan.temperatures == .cpuGPU)
        #expect(plan.power == .system)
    }

    @Test("The popover reads a third of the sensors the Overview does")
    func popoverSensorScope() {
        #expect(SamplingPlan.popoverRequest.temperatures == .cpuGPU)
        #expect(TemperatureScope.cpu < .cpuGPU)
        #expect(TemperatureScope.cpuGPU < .labelled)
        // Narrow scopes may never prune a sensor trace they did not read.
        #expect(!TemperatureScope.cpuGPU.namesEverySensor)
    }

    @Test("A pass that comes round too soon leaves the sensors alone")
    func temperatureFloor() {
        let popover = SamplingDemand(consumers: .popover)
        #expect(
            SamplingPlan.throttlesTemperatures(demand: popover, sinceLastRead: .seconds(1))
        )
        #expect(
            !SamplingPlan.throttlesTemperatures(demand: popover, sinceLastRead: .seconds(4))
        )
        // The two tabs that graph sensors want every point.
        for tab in [MainTab.sensors, .fans] {
            #expect(
                !SamplingPlan.throttlesTemperatures(
                    demand: SamplingDemand(consumers: .window, activeTab: tab),
                    sinceLastRead: .seconds(1)
                ),
                "\(tab.rawValue) must read every pass"
            )
        }
        // A window on another tab is not watching a chart.
        #expect(
            SamplingPlan.throttlesTemperatures(
                demand: SamplingDemand(consumers: .window, activeTab: .overview),
                sinceLastRead: .zero
            )
        )
    }

    @Test("The Windows section of the popover reads nothing of its own")
    func popoverWindowsRequest() {
        let plan = request(SamplingDemand(consumers: .popover, popoverSection: .windows))
        // The menu bar label is all that is left.
        #expect(plan == request(SamplingDemand()))
        #expect(!plan.memory)
        #expect(!plan.fans)
    }

    @Test("The Tools section of the popover reads the fans and nothing else")
    func popoverToolsRequest() {
        let plan = request(SamplingDemand(consumers: .popover, popoverSection: .tools))
        #expect(plan.fans)
        #expect(!plan.memory)
        #expect(!plan.diskSpace)
        #expect(!plan.diskIO)
        // The CPU is the menu bar label's, not the section's.
        #expect(SamplingPlan.popoverRequest(section: .tools).fans)
        #expect(!SamplingPlan.popoverRequest(section: .tools).cpu)
    }

    @Test("Every popover section asks for at most what the Dashboard asks for")
    func popoverSectionsAreSubsets() {
        let dashboard = SamplingPlan.popoverRequest(section: .dashboard)
        for section in PopoverSection.allCases {
            #expect(dashboard.union(SamplingPlan.popoverRequest(section: section)) == dashboard)
        }
    }

    @Test("The Overview reads everything it draws, and no rail list")
    func overviewRequest() {
        let plan = request(SamplingDemand(consumers: .window))
        #expect(plan.cpu)
        #expect(plan.memory)
        #expect(plan.diskSpace)
        #expect(plan.diskIO)
        #expect(plan.fans)
        #expect(plan.temperatures == .labelled)
        // `PSTR` alone: the labelled rails belong to the Sensors tab.
        #expect(plan.power == .system)
    }

    @Test("Every tab reads what it shows and nothing more")
    func perTabRequests() {
        func plan(_ tab: MainTab) -> SampleRequest {
            SamplingPlan.windowRequest(tab: tab, showsUnlabelledSensors: false)
        }
        #expect(plan(.sensors) == SampleRequest(cpu: false, temperatures: .labelled, power: .labelled))
        #expect(plan(.fans) == SampleRequest(cpu: false, temperatures: .labelled, fans: true))
        #expect(plan(.storage) == SampleRequest(cpu: false, diskSpace: true, diskIO: true))
        // The process table comes from `ProcessStore`, not from a pass.
        #expect(plan(.processes) == .nothing)
        for tab in [MainTab.windows, .keepAwake, .backlight, .keyboardLock, .settings] {
            #expect(plan(tab) == .nothing, "\(tab.rawValue) must sample nothing")
        }
        #expect(plan(.overview).readsNothing == false)
    }

    @Test("A tab that shows nothing leaves the idle request untouched")
    func silentTabRequest() {
        for tab in [MainTab.windows, .keepAwake, .backlight, .keyboardLock, .settings, .processes] {
            let plan = request(SamplingDemand(consumers: .window, activeTab: tab))
            #expect(plan == request(SamplingDemand()), "\(tab.rawValue) must add nothing")
        }
    }

    @Test("The Sensors tab with unlabelled sensors on is the only catalog read")
    func sensorTabRequest() {
        let tab = SamplingDemand(consumers: .window, activeTab: .sensors)
        #expect(request(tab, unlabelled: true).temperatures == .everything)
        #expect(request(tab).temperatures == .labelled)
        // A popover over a hidden window whose selected tab is Sensors: the
        // tab is nobody looking, so the catalog stays unread and the popover
        // gets the two dies it draws.
        let popover = SamplingDemand(consumers: .popover, activeTab: .sensors)
        #expect(request(popover, unlabelled: true).temperatures == .cpuGPU)
    }

    @Test("Two consumers read the superset, never less than either alone")
    func unionRequest() {
        let both = SamplingDemand(consumers: [.window, .popover], activeTab: .sensors)
        let plan = request(both, unlabelled: true)
        #expect(plan.temperatures == .everything)
        #expect(plan.power == .labelled)
        #expect(plan.fans)
        #expect(plan.memory)
    }

    @Test("A label metric survives a consumer that does not need it")
    func labelMetricSurvives() {
        // The label wants disk I/O; the window request covers it, and the
        // popover request must not narrow it away.
        let plan = request(SamplingDemand(consumers: .popover), metrics: [.diskIO])
        #expect(plan.diskIO)
    }

    // MARK: - Union

    @Test("Union takes the wider scope of every field")
    func requestUnion() {
        var narrow = SampleRequest(cpu: true, temperatures: .cpu, power: .system)
        let wide = SampleRequest(memory: true, temperatures: .labelled, power: .labelled)
        narrow.formUnion(wide)
        #expect(narrow.cpu)
        #expect(narrow.memory)
        #expect(narrow.temperatures == .labelled)
        #expect(narrow.power == .labelled)
        // And it is symmetric.
        #expect(wide.union(SampleRequest(cpu: true, temperatures: .cpu, power: .system)) == narrow)
    }

    // MARK: - Cadence

    @Test("The refresh interval holds while anything is on screen")
    func interval() {
        let refresh: Double = 2
        #expect(
            SamplingPlan.metricsInterval(
                demand: SamplingDemand(consumers: .popover),
                refreshSeconds: refresh,
                menuBarMetrics: []
            ) == .seconds(refresh)
        )
        #expect(
            SamplingPlan.metricsInterval(
                demand: SamplingDemand(consumers: .window),
                refreshSeconds: refresh,
                menuBarMetrics: []
            ) == .seconds(refresh)
        )
        #expect(
            SamplingPlan.metricsInterval(
                demand: SamplingDemand(),
                refreshSeconds: refresh,
                menuBarMetrics: menuBar
            ) == .seconds(refresh)
        )
    }

    @Test("An idle app with an empty label slows to 5 s")
    func idleInterval() {
        #expect(
            SamplingPlan.metricsInterval(
                demand: SamplingDemand(),
                refreshSeconds: 1,
                menuBarMetrics: []
            ) == SamplingPlan.idleInterval
        )
    }

    @Test("A covered window slows down but keeps reading everything")
    func occludedWindow() {
        let covered = SamplingDemand(consumers: .window, windowOccluded: true)
        // The cadence drops...
        #expect(
            SamplingPlan.metricsInterval(
                demand: covered,
                refreshSeconds: 1,
                menuBarMetrics: menuBar
            ) == SamplingPlan.idleInterval
        )
        // ...and nothing else does: the same pass, so the graphs of a window
        // that comes back have no hole in them.
        #expect(request(covered) == request(SamplingDemand(consumers: .window)))
        #expect(
            SamplingPlan.pollsFans(
                SamplingDemand(consumers: .window, activeTab: .fans, windowOccluded: true)
            )
        )
        #expect(
            SamplingPlan.samplesProcesses(
                SamplingDemand(consumers: .window, activeTab: .processes, windowOccluded: true)
            )
        )
    }

    @Test("An open popover keeps the full cadence over a covered window")
    func occludedWindowWithPopover() {
        let demand = SamplingDemand(consumers: [.window, .popover], windowOccluded: true)
        #expect(
            SamplingPlan.metricsInterval(
                demand: demand,
                refreshSeconds: 1,
                menuBarMetrics: []
            ) == .seconds(1)
        )
    }

    // MARK: - The two stores behind a tab

    @Test("Processes sample for the popover and for their own tab only")
    func processDemand() {
        #expect(SamplingPlan.samplesProcesses(SamplingDemand(consumers: .popover)))
        #expect(
            SamplingPlan.samplesProcesses(
                SamplingDemand(consumers: .window, activeTab: .processes)
            )
        )
        #expect(
            !SamplingPlan.samplesProcesses(
                SamplingDemand(consumers: .window, activeTab: .overview)
            )
        )
        // A selected tab inside a hidden window is nobody looking.
        #expect(!SamplingPlan.samplesProcesses(SamplingDemand(activeTab: .processes)))
    }

    @Test("The popover reads the process table slower than its own tab does")
    func processCadence() {
        // The profiler says one libproc pass over 580 processes is the most
        // expensive thing an open popover does, and it draws three rows.
        #expect(
            SamplingPlan.processInterval(
                SamplingDemand(consumers: .window, activeTab: .processes)
            ) == SamplingPlan.processInterval
        )
        #expect(
            SamplingPlan.processInterval(
                SamplingDemand(consumers: .popover, popoverSection: .dashboard)
            ) == SamplingPlan.popoverProcessInterval
        )
        #expect(SamplingPlan.popoverProcessInterval > SamplingPlan.processInterval)
        // Both at once is somebody watching the table itself.
        #expect(
            SamplingPlan.processInterval(
                SamplingDemand(consumers: [.window, .popover], activeTab: .processes)
            ) == SamplingPlan.processInterval
        )
    }

    @Test("Fans poll for the popover and for their own tab only")
    func fanDemand() {
        #expect(SamplingPlan.pollsFans(SamplingDemand(consumers: .popover)))
        #expect(SamplingPlan.pollsFans(SamplingDemand(consumers: .window, activeTab: .fans)))
        #expect(!SamplingPlan.pollsFans(SamplingDemand(consumers: .window, activeTab: .storage)))
        #expect(!SamplingPlan.pollsFans(SamplingDemand(activeTab: .fans)))
    }

    @Test("Closing the popover restores exactly the idle plan")
    func noLeakAfterClose() {
        let open = SamplingDemand(consumers: .popover)
        var closed = open
        closed.consumers.remove(.popover)
        #expect(closed == SamplingDemand())
        #expect(request(closed) == request(SamplingDemand()))
        #expect(!SamplingPlan.samplesProcesses(closed))
        #expect(!SamplingPlan.pollsFans(closed))
    }

    // MARK: - A label nobody can read

    @Test("Icon only asks for nothing at all, not even the one CPU call")
    func iconOnlyRequest() {
        var demand = SamplingDemand()
        demand.menuBarShowsMetrics = false
        #expect(request(demand) == .nothing)
        #expect(request(demand).readsNothing)
        #expect(!SamplingPlan.samplesMetrics(demand: demand, menuBarMetrics: menuBar))
    }

    @Test("A status item the menu bar has no room for stops every sampler")
    func hiddenStatusItem() {
        // The same flag carries both cases: the setting, and an item the
        // system parked off the edge of a notched menu bar.
        var hidden = SamplingDemand()
        hidden.menuBarShowsMetrics = false
        #expect(!SamplingPlan.samplesMetrics(demand: hidden, menuBarMetrics: menuBar))
        #expect(!SamplingPlan.samplesProcesses(hidden))
        #expect(!SamplingPlan.pollsFans(hidden))
        #expect(hidden.summary == "nothing on screen")
        // And it changes nothing for what is on screen: a window still gets
        // everything its tab draws.
        var window = hidden
        window.consumers = .window
        #expect(SamplingPlan.samplesMetrics(demand: window, menuBarMetrics: []))
        #expect(request(window, metrics: []) == request(SamplingDemand(consumers: .window), metrics: []))
    }

    @Test("A hidden label drops the cadence to the idle one")
    func hiddenLabelInterval() {
        var hidden = SamplingDemand()
        hidden.menuBarShowsMetrics = false
        #expect(
            SamplingPlan.metricsInterval(
                demand: hidden,
                refreshSeconds: 1,
                menuBarMetrics: menuBar
            ) == SamplingPlan.idleInterval
        )
    }

    // MARK: - The power rules

    @Test("On battery with nothing on screen the cadence halves")
    func batteryFactor() {
        let battery = PowerConditions(onBattery: true)
        #expect(
            SamplingPlan.metricsInterval(
                demand: SamplingDemand(),
                refreshSeconds: 1,
                menuBarMetrics: menuBar,
                conditions: battery
            ) == .seconds(2)
        )
        // Somebody looking at the numbers is not the place to save a milliwatt.
        for demand in [SamplingDemand(consumers: .window), SamplingDemand(consumers: .popover)] {
            #expect(
                SamplingPlan.metricsInterval(
                    demand: demand,
                    refreshSeconds: 1,
                    menuBarMetrics: menuBar,
                    conditions: battery
                ) == .seconds(1)
            )
        }
    }

    @Test("Low Power Mode quarters the cadence on battery and halves it on wall power")
    func lowPowerFactor() {
        #expect(
            SamplingPlan.powerFactor(
                demand: SamplingDemand(consumers: .popover),
                conditions: PowerConditions(lowPowerMode: true)
            ) == 2
        )
        let low = PowerConditions(onBattery: true, lowPowerMode: true)
        #expect(
            SamplingPlan.metricsInterval(
                demand: SamplingDemand(consumers: .popover),
                refreshSeconds: 1,
                menuBarMetrics: menuBar,
                conditions: low
            ) == .seconds(4)
        )
        // Four times five seconds is over the cap, so the cap wins.
        #expect(
            SamplingPlan.metricsInterval(
                demand: SamplingDemand(),
                refreshSeconds: 1,
                menuBarMetrics: [],
                conditions: low
            ) == SamplingPlan.maximumInterval
        )
        // Low Power Mode beats the battery rule rather than compounding it.
        #expect(
            SamplingPlan.powerFactor(
                demand: SamplingDemand(),
                conditions: PowerConditions(onBattery: true, lowPowerMode: true)
            ) == 4
        )
    }

    @Test("A serious thermal state is never faster than the idle cadence")
    func thermalFloor() {
        for state in [ProcessInfo.ThermalState.serious, .critical] {
            let hot = PowerConditions(thermalState: state)
            #expect(hot.isThermallyStressed)
            #expect(
                SamplingPlan.metricsInterval(
                    demand: SamplingDemand(consumers: .window),
                    refreshSeconds: 1,
                    menuBarMetrics: menuBar,
                    conditions: hot
                ) == SamplingPlan.idleInterval
            )
        }
        for state in [ProcessInfo.ThermalState.nominal, .fair] {
            #expect(!PowerConditions(thermalState: state).isThermallyStressed)
            #expect(
                SamplingPlan.metricsInterval(
                    demand: SamplingDemand(consumers: .window),
                    refreshSeconds: 1,
                    menuBarMetrics: menuBar,
                    conditions: PowerConditions(thermalState: state)
                ) == .seconds(1)
            )
        }
    }

    @Test("Nothing is ever slower than the cap")
    func intervalCap() {
        let worst = PowerConditions(onBattery: true, lowPowerMode: true, thermalState: .critical)
        #expect(
            SamplingPlan.metricsInterval(
                demand: SamplingDemand(),
                refreshSeconds: 5,
                menuBarMetrics: menuBar,
                conditions: worst
            ) == SamplingPlan.maximumInterval
        )
    }

    @Test("Wall power and a cool machine change nothing at all")
    func neutralConditions() {
        for demand in [SamplingDemand(), SamplingDemand(consumers: .window)] {
            #expect(
                SamplingPlan.metricsInterval(
                    demand: demand,
                    refreshSeconds: 1,
                    menuBarMetrics: menuBar,
                    conditions: PowerConditions()
                ) == SamplingPlan.metricsInterval(
                    demand: demand,
                    refreshSeconds: 1,
                    menuBarMetrics: menuBar
                )
            )
        }
    }

    // MARK: - Tolerance and the badge

    @Test("Every periodic sleep carries a fifth of itself as slack")
    func tolerance() {
        #expect(SamplingPlan.tolerance(for: .seconds(5)) == .seconds(1))
        #expect(SamplingPlan.tolerance(for: .seconds(1)) == .milliseconds(200))
    }

    @Test("The Awake badge ticks on the minute, not on the second")
    func badgeTick() {
        // Two hours left: the text changes when the minute does, so the timer
        // aims at the next boundary.
        #expect(SamplingPlan.badgeTick(remainingSeconds: 7200) == .seconds(60))
        #expect(SamplingPlan.badgeTick(remainingSeconds: 130) == .seconds(10))
        #expect(SamplingPlan.badgeTick(remainingSeconds: 61) == .seconds(1))
        // The last minute says "under 1m" the whole way down, and the expiry
        // has a timer of its own, so this is only a drift check.
        #expect(SamplingPlan.badgeTick(remainingSeconds: 60) == .seconds(15))
        #expect(SamplingPlan.badgeTick(remainingSeconds: 5) == .seconds(15))
        #expect(SamplingPlan.badgeTick(remainingSeconds: 0) == .seconds(15))
        // Never zero: a timer that fires at once is a spin.
        for remaining in 0...3600 {
            #expect(SamplingPlan.badgeTick(remainingSeconds: remaining) >= .seconds(1))
        }
    }

    @Test("The demand names itself for the log")
    func summary() {
        #expect(SamplingDemand().summary == "menu bar only")
        #expect(SamplingDemand(consumers: .popover).summary == "popover(dashboard)")
        #expect(
            SamplingDemand(
                consumers: [.window, .popover],
                activeTab: .fans,
                popoverSection: .tools
            ).summary == "window(fans) + popover(tools)"
        )
    }

    // MARK: - The popover sections behind the two stores

    @Test("Processes sample for the Dashboard section alone")
    func processDemandPerSection() {
        #expect(
            SamplingPlan.samplesProcesses(
                SamplingDemand(consumers: .popover, popoverSection: .dashboard)
            )
        )
        for section in [PopoverSection.windows, .tools] {
            #expect(
                !SamplingPlan.samplesProcesses(
                    SamplingDemand(consumers: .popover, popoverSection: section)
                ),
                "\(section.rawValue) must not sample processes"
            )
        }
    }

    @Test("Fans poll for the Dashboard and the Tools sections, never for Windows")
    func fanDemandPerSection() {
        #expect(
            SamplingPlan.pollsFans(SamplingDemand(consumers: .popover, popoverSection: .dashboard))
        )
        #expect(
            SamplingPlan.pollsFans(SamplingDemand(consumers: .popover, popoverSection: .tools))
        )
        #expect(
            !SamplingPlan.pollsFans(SamplingDemand(consumers: .popover, popoverSection: .windows))
        )
        // A remembered section with the popover closed is nobody looking.
        #expect(!SamplingPlan.pollsFans(SamplingDemand(popoverSection: .tools)))
    }

    @Test("A silent tab or section does not raise the cadence")
    func silentConsumerInterval() {
        let windows = SamplingDemand(consumers: .window, activeTab: .windows)
        #expect(
            SamplingPlan.metricsInterval(
                demand: windows,
                refreshSeconds: 1,
                menuBarMetrics: []
            ) == SamplingPlan.idleInterval
        )
        // With a label to draw, the menu bar's own cadence takes over.
        #expect(
            SamplingPlan.metricsInterval(
                demand: windows,
                refreshSeconds: 1,
                menuBarMetrics: menuBar
            ) == .seconds(1)
        )
        let popoverWindows = SamplingDemand(consumers: .popover, popoverSection: .windows)
        #expect(
            SamplingPlan.metricsInterval(
                demand: popoverWindows,
                refreshSeconds: 1,
                menuBarMetrics: []
            ) == SamplingPlan.idleInterval
        )
        // Tools shows a fan, so it pays the user's interval.
        #expect(
            SamplingPlan.metricsInterval(
                demand: SamplingDemand(consumers: .popover, popoverSection: .tools),
                refreshSeconds: 1,
                menuBarMetrics: []
            ) == .seconds(1)
        )
    }
}

/// The rows the Processes tab draws, derived once per sample.
@Suite("Process rows")
struct ProcessRowsTests {
    private func row(
        pid: Int32,
        name: String,
        uid: uid_t = 501,
        cpu: Double?,
        memory: UInt64?
    ) -> ProcessTableRow {
        ProcessTableRow(
            info: ProcessInfoRow(
                pid: pid,
                parentPID: 1,
                uid: uid,
                command: name,
                name: name,
                executablePath: "/usr/bin/\(name)",
                startAbsoluteTime: 1,
                cpuPercent: cpu,
                cpuNanoseconds: nil,
                memoryBytes: memory
            ),
            userName: uid == 501 ? "serene" : "root"
        )
    }

    private var sample: [ProcessTableRow] {
        [
            row(pid: 1, name: "launchd", uid: 0, cpu: 0.5, memory: 12_000_000),
            row(pid: 2, name: "Xcode", cpu: 40, memory: 900_000_000),
            row(pid: 3, name: "Vent", cpu: 0.3, memory: 40_000_000),
            row(pid: 4, name: "kernel_task", uid: 0, cpu: 8, memory: nil),
        ]
    }

    @Test("One derivation answers the table, both top lists and the two counts")
    func derives() {
        let rows = ProcessRows.make(
            rows: sample,
            scope: .all,
            currentUID: 501,
            query: "",
            sortOrder: [ProcessComparator(key: .cpu, order: .reverse)]
        )
        #expect(rows.all.count == 4)
        #expect(rows.visible.map(\.name) == ["Xcode", "kernel_task", "launchd", "Vent"])
        #expect(rows.topByCPU.first?.name == "Xcode")
        #expect(rows.topByMemory.first?.name == "Xcode")
        #expect(rows.restrictedCount == 1)
        #expect(rows.totalCPUPercent == 48.8)
    }

    @Test("The scope and the search box narrow the table and nothing else")
    func filters() {
        let mine = ProcessRows.make(
            rows: sample,
            scope: .mine,
            currentUID: 501,
            query: "",
            sortOrder: [ProcessComparator(key: .name)]
        )
        #expect(mine.visible.map(\.name) == ["Vent", "Xcode"])
        // The top lists and the counts are about the machine, not about what
        // the user filtered down to.
        #expect(mine.topByCPU.count == 4)
        #expect(mine.restrictedCount == 1)

        let search = ProcessRows.make(
            rows: sample,
            scope: .all,
            currentUID: 501,
            query: "ker",
            sortOrder: [ProcessComparator(key: .name)]
        )
        #expect(search.visible.map(\.name) == ["kernel_task"])
    }

    @Test("The same input derives the same rows, so nothing moves under a click")
    func stable() {
        let order = [ProcessComparator(key: .cpu, order: .reverse)]
        let first = ProcessRows.make(rows: sample, scope: .all, currentUID: 501, query: "", sortOrder: order)
        let second = ProcessRows.make(rows: sample, scope: .all, currentUID: 501, query: "", sortOrder: order)
        #expect(first == second)
    }

    @Test("An empty sample derives empty rows and no arithmetic")
    func empty() {
        let rows = ProcessRows.make(
            rows: [],
            scope: .all,
            currentUID: 501,
            query: "x",
            sortOrder: [ProcessComparator(key: .cpu, order: .reverse)]
        )
        #expect(rows == ProcessRows())
    }
}

/// The bounded cache behind the rendered menu bar labels.
@Suite("LRU cache")
struct LRUCacheTests {
    @Test("It gives back what it was given")
    func roundTrip() {
        var cache = LRUCache<String, Int>(capacity: 3)
        cache.insert(1, forKey: "a")
        #expect(cache.value(forKey: "a") == 1)
        #expect(cache.value(forKey: "b") == nil)
        #expect(cache.count == 1)
    }

    @Test("It never grows past its capacity")
    func bounded() {
        var cache = LRUCache<Int, Int>(capacity: 4)
        for index in 0..<100 { cache.insert(index, forKey: index) }
        #expect(cache.count == 4)
        #expect(cache.keysByAge == [96, 97, 98, 99])
        #expect(cache.value(forKey: 95) == nil)
        #expect(cache.value(forKey: 99) == 99)
    }

    @Test("The entry that has not been used in the longest time goes first")
    func evictsLeastRecentlyUsed() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")
        // Reading "a" makes "b" the old one.
        #expect(cache.value(forKey: "a") == 1)
        cache.insert(3, forKey: "c")
        #expect(cache.value(forKey: "b") == nil)
        #expect(cache.value(forKey: "a") == 1)
        #expect(cache.value(forKey: "c") == 3)
    }

    @Test("Writing a key again replaces it instead of adding a second entry")
    func overwrite() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "a")
        #expect(cache.count == 1)
        #expect(cache.value(forKey: "a") == 2)
    }

    @Test("A capacity below one is still a cache of one")
    func minimumCapacity() {
        var cache = LRUCache<String, Int>(capacity: 0)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")
        #expect(cache.count == 1)
        #expect(cache.value(forKey: "b") == 2)
    }

    @Test("Emptying it keeps nothing behind")
    func removeAll() {
        var cache = LRUCache<String, Int>(capacity: 3)
        cache.insert(1, forKey: "a")
        cache.removeAll()
        #expect(cache.isEmpty)
        #expect(cache.keysByAge.isEmpty)
        #expect(cache.value(forKey: "a") == nil)
    }
}

/// The sidebar and the launch arguments that name a tab.
@Suite("Main tabs")
struct MainTabTests {
    @Test("Every tab sits in exactly one sidebar section, in the sidebar order")
    func sections() {
        #expect(MainTabSection.orderedTabs == MainTab.allCases)
        #expect(MainTabSection.monitor.tabs == [.overview, .sensors, .processes, .storage])
        #expect(MainTabSection.control.tabs == [.fans, .windows, .keepAwake])
        #expect(MainTabSection.tools.tabs == [.keyboardLock, .backlight])
        #expect(MainTabSection.app.tabs == [.settings])
    }

    @Test("Every tab has a title and a symbol")
    func titles() {
        for tab in MainTab.allCases {
            #expect(!tab.title.isEmpty)
            #expect(!tab.symbolName.isEmpty)
        }
    }

    @Test("`--tab` takes the new names, in any case and with any separator")
    func argument() {
        #expect(MainTab(argument: "windows") == .windows)
        #expect(MainTab(argument: "keepAwake") == .keepAwake)
        #expect(MainTab(argument: "keep-awake") == .keepAwake)
        #expect(MainTab(argument: "KEEP_AWAKE") == .keepAwake)
        #expect(MainTab(argument: "backlight") == .backlight)
        #expect(MainTab(argument: "keyboardlock") == .keyboardLock)
        #expect(MainTab(argument: "nonsense") == nil)
        for tab in MainTab.allCases {
            #expect(MainTab(argument: tab.rawValue) == tab)
        }
    }

    @Test("`--popover-section` takes the three section names")
    func popoverSectionArgument() {
        for section in PopoverSection.allCases {
            #expect(PopoverSection(argument: section.rawValue) == section)
            #expect(PopoverSection(argument: section.rawValue.uppercased()) == section)
        }
        #expect(PopoverSection(argument: "nonsense") == nil)
        // Cmd-1, Cmd-2, Cmd-3, in the order of the segmented control.
        #expect(PopoverSection.allCases.map(\.shortcutKey) == ["1", "2", "3"])
    }
}
