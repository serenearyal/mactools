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
        #expect(plan.temperatures == .labelled)
        #expect(plan.power == .system)
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
        let popover = SamplingDemand(consumers: .popover, activeTab: .sensors)
        #expect(request(popover, unlabelled: true).temperatures == .labelled)
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
