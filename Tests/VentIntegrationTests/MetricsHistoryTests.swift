import SMCKit
import SysMetrics
import Testing

/// What the history keeps and what it drops.
///
/// The source file under test is compiled into this bundle (see `project.yml`),
/// so the app and the tests share one copy of the rules.
@Suite("Metrics history")
struct MetricsHistoryTests {
    private func reading(_ key: SMCFourCC, _ celsius: Double, label: String = "Sensor") -> TemperatureReading {
        TemperatureReading(key: key, label: label, category: .cpuPerformance, celsius: celsius)
    }

    private func sample(
        _ readings: [TemperatureReading],
        scope: TemperatureScope
    ) -> MetricsSample {
        var sample = MetricsSample()
        sample.temperatures = readings
        sample.temperatureScope = scope
        return sample
    }

    private func history(after samples: [MetricsSample]) -> MetricsHistory {
        var history = MetricsHistory()
        for sample in samples {
            history.append(sample, snapshot: MetricsSnapshot())
        }
        return history
    }

    @Test("A full pass adds every sensor it read")
    func adds() {
        let history = history(after: [
            sample([reading("Tp01", 40), reading("Tf01", 30)], scope: .everything)
        ])
        #expect(history.sensors.count == 2)
        #expect(history.sensors["Tp01"]?.current == 40)
    }

    @Test("A trace missing from a full pass is dropped")
    func dropsAbsentTrace() {
        // The Sensors tab with the unlabelled sensors on, then off: the
        // unlabelled trace must not stay frozen in the table.
        let history = history(after: [
            sample([reading("Tp01", 40), reading("Tf01", 30)], scope: .everything),
            sample([reading("Tp01", 41)], scope: .labelled),
        ])
        #expect(Set(history.sensors.keys) == ["Tp01"])
        #expect(history.orderedSensors.count == 1)
    }

    @Test("A narrow menu bar pass never wipes the table")
    func keepsTraceAfterNarrowPass() {
        var history = history(after: [
            sample([reading("Tp01", 40), reading("Tf01", 30)], scope: .everything)
        ])
        history.append(sample([reading("Tp01", 42)], scope: .cpu), snapshot: MetricsSnapshot())
        #expect(history.sensors.count == 2)
        // The one sensor the narrow pass did read is still up to date.
        #expect(history.sensors["Tp01"]?.current == 42)
        // And the one it did not keeps the value it had.
        #expect(history.sensors["Tf01"]?.current == 30)
    }

    @Test("A full pass that answered with nothing keeps what there is")
    func emptyFullPassKeepsTraces() {
        var history = history(after: [sample([reading("Tp01", 40)], scope: .labelled)])
        history.append(sample([], scope: .labelled), snapshot: MetricsSnapshot())
        #expect(history.sensors.count == 1)
    }

    @Test("A pass with no temperatures at all leaves the traces alone")
    func noTemperatureSampleKeepsTraces() {
        var history = history(after: [sample([reading("Tp01", 40)], scope: .labelled)])
        history.append(MetricsSample(), snapshot: MetricsSnapshot())
        #expect(history.sensors.count == 1)
    }

    @Test("Extremes follow the trace, and the order is stable")
    func tracksExtremes() throws {
        let history = history(after: [
            sample([reading("Tp01", 40, label: "CPU die 1")], scope: .labelled),
            sample([reading("Tp01", 55, label: "CPU die 1")], scope: .labelled),
            sample([reading("Tp01", 45, label: "CPU die 1")], scope: .labelled),
        ])
        let trace = try #require(history.sensors["Tp01"])
        #expect(trace.minimum == 40)
        #expect(trace.maximum == 55)
        #expect(trace.current == 45)
        #expect(history.orderedSensors.map(\.label) == ["CPU die 1"])
    }

    @Test("Only a full scope may remove a sensor")
    func scopeRule() {
        #expect(!TemperatureScope.none.namesEverySensor)
        #expect(!TemperatureScope.cpu.namesEverySensor)
        #expect(TemperatureScope.labelled.namesEverySensor)
        #expect(TemperatureScope.everything.namesEverySensor)
    }
}
