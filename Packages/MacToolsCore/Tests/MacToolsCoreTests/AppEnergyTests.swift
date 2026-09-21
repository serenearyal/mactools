import Foundation
import Testing

@testable import SysMetrics

@Suite("App grouping")
struct AppGroupingTests {
    @Test("An executable inside a bundle belongs to that bundle")
    func plainBundle() {
        let identity = AppGrouping.identity(
            executablePath: "/Applications/Xcode.app/Contents/MacOS/Xcode",
            processName: "Xcode"
        )
        #expect(identity.id == "/Applications/Xcode.app")
        #expect(identity.name == "Xcode")
        #expect(identity.bundlePath == "/Applications/Xcode.app")
    }

    @Test("A helper inside a nested bundle counts for the outermost app")
    func nestedBundle() {
        let renderer = AppGrouping.identity(
            executablePath: "/Applications/Arc.app/Contents/Frameworks/ArcCore.framework/Helpers/Browser Helper (Renderer).app/Contents/MacOS/Browser Helper (Renderer)",
            processName: "Browser Helper (Renderer)"
        )
        let browser = AppGrouping.identity(
            executablePath: "/Applications/Arc.app/Contents/MacOS/Arc",
            processName: "Arc"
        )
        #expect(renderer == browser)
        #expect(renderer.name == "Arc")
    }

    @Test("A process with no bundle is its own app")
    func noBundle() {
        let kernel = AppGrouping.identity(executablePath: nil, processName: "kernel_task")
        #expect(kernel.id == "kernel_task")
        #expect(kernel.name == "kernel_task")
        #expect(kernel.bundlePath == nil)

        let windowServer = AppGrouping.identity(
            executablePath: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
            processName: "WindowServer"
        )
        #expect(windowServer.id == "WindowServer")
        #expect(windowServer.bundlePath == nil)
    }

    @Test("Two apps of the same name in different folders stay apart")
    func sameNameDifferentPaths() {
        let installed = AppGrouping.identity(
            executablePath: "/Applications/Notes.app/Contents/MacOS/Notes",
            processName: "Notes"
        )
        let sandbox = AppGrouping.identity(
            executablePath: "/Users/me/build/Notes.app/Contents/MacOS/Notes",
            processName: "Notes"
        )
        #expect(installed.name == sandbox.name)
        #expect(installed != sandbox)
        #expect(installed.id != sandbox.id)
    }

    @Test("A path that only ends in .app is a file, not a bundle")
    func pathShapes() {
        #expect(AppGrouping.bundlePath(forExecutablePath: "/tmp/thing.app") == nil)
        #expect(AppGrouping.bundlePath(forExecutablePath: "/usr/bin/ssh") == nil)
        #expect(AppGrouping.bundlePath(forExecutablePath: "") == nil)
        // A component that is nothing but the extension names no app.
        #expect(AppGrouping.bundlePath(forExecutablePath: "/tmp/.app/Contents/MacOS/x") == nil)
        #expect(AppGrouping.bundlePath(forExecutablePath: "relative/A.app/Contents/MacOS/A") == nil)
    }
}

@Suite("Process energy deltas")
struct ProcessEnergyMathTests {
    private func sample(_ energy: UInt64, start: UInt64? = 7) -> ProcessEnergySample {
        ProcessEnergySample(energyNanojoules: energy, startAbsoluteTime: start)
    }

    @Test("The delta is the rise of the counter")
    func rise() {
        #expect(ProcessEnergyMath.delta(previous: sample(100), current: sample(450)) == 350)
    }

    @Test("A first reading has nothing to subtract from")
    func firstReading() {
        #expect(ProcessEnergyMath.delta(previous: nil, current: sample(450)) == 0)
    }

    @Test("A reused pid contributes nothing, never a negative")
    func reusedPID() {
        let previous = sample(9_000, start: 7)
        let current = sample(12, start: 8)
        #expect(ProcessEnergyMath.delta(previous: previous, current: current) == 0)
    }

    @Test("A counter that went backwards contributes nothing")
    func counterReset() {
        #expect(ProcessEnergyMath.delta(previous: sample(9_000), current: sample(12)) == 0)
    }

    @Test("A counter that did not move contributes nothing")
    func idle() {
        #expect(ProcessEnergyMath.delta(previous: sample(500), current: sample(500)) == 0)
    }
}

@Suite("App energy window")
struct AppEnergyWindowTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func row(
        pid: Int32,
        name: String,
        path: String?,
        energy: UInt64?,
        startTime: UInt64 = 1
    ) -> ProcessInfoRow {
        ProcessInfoRow(
            pid: pid,
            parentPID: 1,
            uid: 501,
            command: name,
            name: name,
            executablePath: path,
            startAbsoluteTime: startTime,
            cpuPercent: nil,
            cpuNanoseconds: nil,
            memoryBytes: 1024,
            energyNanojoules: energy
        )
    }

    /// 1 W for one second is 1 J is 1e9 nJ.
    private let joule: UInt64 = 1_000_000_000

    @Test("One pass is a baseline, so the list is empty until the second")
    func needsTwoSamples() {
        var window = AppEnergyWindow()
        window.add([row(pid: 1, name: "Arc", path: "/Applications/Arc.app/Contents/MacOS/Arc", energy: 0)], at: start)
        #expect(window.isEmpty)
        #expect(window.topApps().isEmpty)
        #expect(window.coveredSeconds == 0)

        window.add(
            [row(pid: 1, name: "Arc", path: "/Applications/Arc.app/Contents/MacOS/Arc", energy: 2 * joule)],
            at: start.addingTimeInterval(2)
        )
        #expect(!window.isEmpty)
        #expect(window.coveredSeconds == 2)
        let apps = window.topApps()
        #expect(apps.count == 1)
        #expect(apps[0].name == "Arc")
        // 2 J over 2 s is 1 W.
        #expect(abs(apps[0].watts - 1) < 1e-9)
        #expect(abs(apps[0].share - 1) < 1e-9)
        #expect(apps[0].processCount == 1)
    }

    @Test("Helpers of one app are one row with every process counted")
    func groupsHelpers() {
        var window = AppEnergyWindow()
        func pass(_ energy: UInt64, at date: Date) {
            window.add(
                [
                    row(pid: 1, name: "Arc", path: "/Applications/Arc.app/Contents/MacOS/Arc", energy: energy),
                    row(
                        pid: 2,
                        name: "Browser Helper (Renderer)",
                        path: "/Applications/Arc.app/Contents/Frameworks/ArcCore.framework/Helpers/Browser Helper (Renderer).app/Contents/MacOS/Browser Helper (Renderer)",
                        energy: energy
                    ),
                ],
                at: date
            )
        }
        pass(0, at: start)
        pass(3 * joule, at: start.addingTimeInterval(1))
        let apps = window.topApps()
        #expect(apps.count == 1)
        #expect(apps[0].name == "Arc")
        #expect(apps[0].processCount == 2)
        // Two processes, 3 J each, over one second.
        #expect(abs(apps[0].watts - 6) < 1e-9)
    }

    @Test("The shares of every app sum to 1")
    func sharesSumToOne() {
        var window = AppEnergyWindow()
        func pass(_ energies: [UInt64], at date: Date) {
            window.add(
                energies.enumerated().map { index, energy in
                    row(
                        pid: Int32(index + 1),
                        name: "App\(index)",
                        path: "/Applications/App\(index).app/Contents/MacOS/App\(index)",
                        energy: energy
                    )
                },
                at: date
            )
        }
        pass([0, 0, 0, 0], at: start)
        pass([joule, 2 * joule, 3 * joule, 4 * joule], at: start.addingTimeInterval(1))
        let apps = window.topApps(limit: 10)
        #expect(apps.count == 4)
        #expect(abs(apps.reduce(0) { $0 + $1.share } - 1) < 1e-9)
        #expect(apps.map(\.name) == ["App3", "App2", "App1", "App0"])
        // The top three of four are less than the whole.
        #expect(window.topApps(limit: 3).reduce(0) { $0 + $1.share } < 1)
    }

    @Test("Equal watts keep a stable order instead of shuffling")
    func stableTies() {
        var window = AppEnergyWindow()
        func pass(_ energy: UInt64, at date: Date) {
            window.add(
                ["Cello", "Alto", "Bass"].enumerated().map { index, name in
                    row(
                        pid: Int32(index + 1),
                        name: name,
                        path: "/Applications/\(name).app/Contents/MacOS/\(name)",
                        energy: energy
                    )
                },
                at: date
            )
        }
        pass(0, at: start)
        pass(joule, at: start.addingTimeInterval(1))
        #expect(window.topApps().map(\.name) == ["Alto", "Bass", "Cello"])
        // The same rows again give the same order.
        pass(2 * joule, at: start.addingTimeInterval(2))
        #expect(window.topApps().map(\.name) == ["Alto", "Bass", "Cello"])
    }

    @Test("A pid that vanished and a reused pid contribute nothing")
    func vanishedAndReusedPIDs() {
        var window = AppEnergyWindow()
        let arc = "/Applications/Arc.app/Contents/MacOS/Arc"
        let mail = "/Applications/Mail.app/Contents/MacOS/Mail"
        window.add(
            [
                row(pid: 1, name: "Arc", path: arc, energy: 5 * joule, startTime: 10),
                row(pid: 2, name: "Mail", path: mail, energy: 9 * joule, startTime: 20),
            ],
            at: start
        )
        // Pid 1 is gone. Pid 2 is another process now: same pid, new start
        // time, and a counter that starts again from a low number.
        window.add(
            [row(pid: 2, name: "Mail", path: mail, energy: joule, startTime: 99)],
            at: start.addingTimeInterval(1)
        )
        #expect(window.topApps().isEmpty)

        // The new pid 2 is measured from its own baseline.
        window.add(
            [row(pid: 2, name: "Mail", path: mail, energy: 3 * joule, startTime: 99)],
            at: start.addingTimeInterval(2)
        )
        let apps = window.topApps()
        #expect(apps.count == 1)
        #expect(apps[0].name == "Mail")
        // 2 J over the 2 s the window covers is 1 W.
        #expect(abs(apps[0].watts - 1) < 1e-9)
    }

    @Test("A row with no readable counter starts again instead of spiking")
    func unreadableCounter() {
        var window = AppEnergyWindow()
        let path = "/Applications/Arc.app/Contents/MacOS/Arc"
        window.add([row(pid: 1, name: "Arc", path: path, energy: joule)], at: start)
        // The helper did not answer for this pass.
        window.add([row(pid: 1, name: "Arc", path: path, energy: nil)], at: start.addingTimeInterval(1))
        // It answered again, with a counter that covers both intervals.
        window.add([row(pid: 1, name: "Arc", path: path, energy: 100 * joule)], at: start.addingTimeInterval(2))
        #expect(window.topApps().isEmpty)
        #expect(window.coveredSeconds == 2)
    }

    @Test("Slices older than the window fall off the front")
    func trimsTheWindow() {
        var window = AppEnergyWindow(windowSeconds: 10)
        let path = "/Applications/Arc.app/Contents/MacOS/Arc"
        var energy: UInt64 = 0
        for second in 0...30 {
            window.add(
                [row(pid: 1, name: "Arc", path: path, energy: energy)],
                at: start.addingTimeInterval(Double(second))
            )
            energy += joule
        }
        // Ten one-second slices, not thirty.
        #expect(window.coveredSeconds == 10)
        #expect(abs(window.topApps()[0].watts - 1) < 1e-9)
    }

    @Test("A gap longer than the window drops it rather than averaging the gap")
    func longGap() {
        var window = AppEnergyWindow(windowSeconds: 10)
        let path = "/Applications/Arc.app/Contents/MacOS/Arc"
        window.add([row(pid: 1, name: "Arc", path: path, energy: 0)], at: start)
        window.add([row(pid: 1, name: "Arc", path: path, energy: joule)], at: start.addingTimeInterval(1))
        #expect(window.coveredSeconds == 1)
        // The tab was off screen for an hour.
        window.add(
            [row(pid: 1, name: "Arc", path: path, energy: 4_000 * joule)],
            at: start.addingTimeInterval(3_600)
        )
        #expect(window.topApps().isEmpty)
        #expect(window.coveredSeconds == 0)
        // And the pass after it measures the real interval again.
        window.add(
            [row(pid: 1, name: "Arc", path: path, energy: 4_002 * joule)],
            at: start.addingTimeInterval(3_602)
        )
        #expect(window.coveredSeconds == 2)
        #expect(abs(window.topApps()[0].watts - 1) < 1e-9)
    }

    @Test("Two passes in the same instant are one pass")
    func tooCloseTogether() {
        var window = AppEnergyWindow()
        let path = "/Applications/Arc.app/Contents/MacOS/Arc"
        window.add([row(pid: 1, name: "Arc", path: path, energy: 0)], at: start)
        window.add([row(pid: 1, name: "Arc", path: path, energy: joule)], at: start.addingTimeInterval(0.01))
        #expect(window.isEmpty)
        // The energy of the skipped reading is not lost: the next slice has it.
        window.add([row(pid: 1, name: "Arc", path: path, energy: 2 * joule)], at: start.addingTimeInterval(2))
        #expect(abs(window.topApps()[0].watts - 1) < 1e-9)
    }

    @Test("A window that measured nothing but zeros lists nothing")
    func allZero() {
        var window = AppEnergyWindow()
        let path = "/Applications/Arc.app/Contents/MacOS/Arc"
        window.add([row(pid: 1, name: "Arc", path: path, energy: 7)], at: start)
        window.add([row(pid: 1, name: "Arc", path: path, energy: 7)], at: start.addingTimeInterval(1))
        #expect(window.topApps().isEmpty)
    }

    @Test("Reset forgets the window and the baselines")
    func reset() {
        var window = AppEnergyWindow()
        let path = "/Applications/Arc.app/Contents/MacOS/Arc"
        window.add([row(pid: 1, name: "Arc", path: path, energy: 0)], at: start)
        window.add([row(pid: 1, name: "Arc", path: path, energy: joule)], at: start.addingTimeInterval(1))
        window.reset()
        #expect(window.isEmpty)
        #expect(window.coveredSeconds == 0)
        window.add([row(pid: 1, name: "Arc", path: path, energy: 9 * joule)], at: start.addingTimeInterval(2))
        #expect(window.isEmpty)
    }

    @Test("A limit of nothing asks for nothing")
    func zeroLimit() {
        var window = AppEnergyWindow()
        let path = "/Applications/Arc.app/Contents/MacOS/Arc"
        window.add([row(pid: 1, name: "Arc", path: path, energy: 0)], at: start)
        window.add([row(pid: 1, name: "Arc", path: path, energy: joule)], at: start.addingTimeInterval(1))
        #expect(window.topApps(limit: 0).isEmpty)
    }
}
