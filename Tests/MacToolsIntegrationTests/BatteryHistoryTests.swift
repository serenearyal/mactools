import Foundation
import SysMetrics
import Testing

/// The 24 h battery trail behind the Battery tab.
///
/// The source file under test is compiled into this bundle (see `project.yml`),
/// so the app and the tests share one copy of the rules.
@Suite("Battery history")
struct BatteryHistoryTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(
        percent: Int,
        charging: Bool = false,
        read: Bool = true,
        at date: Date
    ) -> MetricsSample {
        var sample = MetricsSample()
        sample.date = date
        sample.battery = BatteryReading(
            percent: percent,
            isPluggedIn: charging,
            isCharging: charging
        )
        sample.batteryRead = read
        return sample
    }

    private func history(_ samples: [MetricsSample]) -> MetricsHistory {
        var history = MetricsHistory()
        for sample in samples {
            history.append(sample, snapshot: MetricsSnapshot())
        }
        return history
    }

    @Test("Every battery read is one point, with its own clock time")
    func onePointPerRead() {
        let result = history([
            sample(percent: 80, at: start),
            sample(percent: 79, at: start.addingTimeInterval(30)),
            sample(percent: 79, charging: true, at: start.addingTimeInterval(60)),
        ])
        #expect(result.battery.count == 3)
        #expect(result.battery.map(\.percent) == [80, 79, 79])
        #expect(result.battery.map(\.isCharging) == [false, false, true])
        #expect(result.battery.first?.date == start)
        #expect(result.battery.last?.date == start.addingTimeInterval(60))
    }

    @Test("A pass that did not read the battery adds no point")
    func onlyRealReads() {
        // The store carries the old reading through the passes between two
        // reads; plotting those would draw a flat line over a gap.
        let result = history([
            sample(percent: 80, at: start),
            sample(percent: 80, read: false, at: start.addingTimeInterval(1)),
            sample(percent: 80, read: false, at: start.addingTimeInterval(2)),
        ])
        #expect(result.battery.count == 1)
        // A Mac with no battery reads and finds nothing, and that is no point
        // either.
        var empty = MetricsSample()
        empty.batteryRead = true
        #expect(history([empty]).battery.isEmpty)
    }

    @Test("Points older than a day fall off the front")
    func keepsOneDay() {
        let day = MetricsHistory.batteryWindow
        let result = history([
            sample(percent: 100, at: start),
            sample(percent: 90, at: start.addingTimeInterval(day / 2)),
            sample(percent: 80, at: start.addingTimeInterval(day)),
            sample(percent: 70, at: start.addingTimeInterval(day + 60)),
        ])
        // The first point is more than a day behind the newest one now.
        #expect(result.battery.map(\.percent) == [90, 80, 70])
        #expect(result.battery.allSatisfy { start.addingTimeInterval(day + 60).timeIntervalSince($0.date) <= day })
    }

    @Test("A pass that reads faster than the floor still cannot grow without bound")
    func capacityCap() {
        var history = MetricsHistory()
        for step in 0..<(MetricsHistory.batteryCapacity + 500) {
            history.append(
                sample(percent: 50, at: start.addingTimeInterval(Double(step))),
                snapshot: MetricsSnapshot()
            )
        }
        #expect(history.battery.count == MetricsHistory.batteryCapacity)
        // The oldest ones are the ones that went.
        #expect(history.battery.first?.date == start.addingTimeInterval(500))
    }
}
