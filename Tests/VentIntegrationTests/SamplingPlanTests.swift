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

    @Test("The window reads everything")
    func windowRequest() {
        let plan = request(SamplingDemand(consumers: .window))
        #expect(plan == SampleRequest.everything)
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
        #expect(SamplingDemand(consumers: .popover).summary == "popover")
        #expect(
            SamplingDemand(consumers: [.window, .popover], activeTab: .fans).summary
                == "window(fans) + popover"
        )
    }
}
