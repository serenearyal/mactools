import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WindowKit

/// The integration test of the mover, driven from inside the app.
///
/// An XCTest bundle has no Accessibility grant and an unbundled binary vends no
/// accessibility server at all, so neither side of a window move can be tested
/// from `xcodebuild test`. This runs in the signed app, which does have the
/// grant, against `MacToolsAXProbe`: an app of ours, launched by us, that exists to
/// be pushed around.
///
/// It touches nothing else. Every move goes to the probe window it found by
/// title, and the probe is asked to quit at the end.
@MainActor
enum WindowSelfTest {
    struct Row {
        let name: String
        let passed: Bool
        let expected: String
        let actual: String
    }

    /// 1 pt: an accessibility write and its read back differ by a point on a
    /// scaled display, and nothing smaller than a point is visible.
    static let tolerance: CGFloat = 1
    /// The probe needs a moment to be ready to answer accessibility calls.
    private static let settle = Duration.milliseconds(120)

    static func run(probePath: String, outputDirectory: String?, services: AppServices) {
        Task { @MainActor in
            let rows = await drive(probePath: probePath, services: services)
            write(rows: rows, to: outputDirectory)
            NSApp.terminate(nil)
        }
    }

    // MARK: - The run

    private static func drive(probePath: String, services: AppServices) async -> [Row] {
        guard AXIsProcessTrusted() else {
            return [Row(name: "accessibility", passed: false, expected: "trusted", actual: "not trusted")]
        }
        guard let screen = ScreenList.screen(containing: NSScreen.main?.visibleFrame ?? .zero) else {
            return [Row(name: "screen", passed: false, expected: "a display", actual: "none")]
        }

        let title = "MacTools AX Probe \(UUID().uuidString.prefix(8))"
        let start = CGRect(
            x: screen.visibleFrame.minX + 60,
            y: screen.visibleFrame.minY + 60,
            width: 700,
            height: 520
        )
        guard let probe = await launch(probePath: probePath, title: title, frame: start) else {
            return [Row(name: "probe launch", passed: false, expected: probePath, actual: "did not start")]
        }
        defer { probe.terminate() }

        guard let target = await findWindow(pid: probe.processIdentifier, title: title) else {
            return [Row(name: "probe window", passed: false, expected: title, actual: "not found by AX")]
        }
        var rows = [
            Row(
                name: "probe window found",
                passed: true,
                expected: title,
                actual: "\(text(target.frame)) on \(target.displayName)"
            )
        ]
        let origin = target.frame
        let mover = services.windows.mover

        // Every placement, one press each, from a clean ladder.
        for action in WindowAction.placements {
            mover.resetCycle()
            let current = target.refreshed()?.frame
            guard let expected = WindowLayout.target(
                action: action,
                on: screen,
                current: current,
                gap: 0
            ) else { continue }
            rows.append(await press(action, on: target, mover: mover, gap: 0, expecting: expected))
        }

        // The ladder: a half pressed three times walks 1/2, 2/3, 1/3.
        mover.resetCycle()
        for span in [WindowSlot.Span.half, .twoThirds, .third] {
            let slot = WindowSlot(axis: .horizontal, position: .first, span: span)
            guard let expected = WindowLayout.target(slot: slot, on: screen, gap: 0) else { continue }
            rows.append(
                await press(
                    .leftHalf,
                    on: target,
                    mover: mover,
                    gap: 0,
                    expecting: expected,
                    name: "leftHalf cycle \(span.rawValue)"
                )
            )
        }

        // The thirds ladder: first, center, last.
        mover.resetCycle()
        for position in [WindowSlot.Position.first, .center, .last] {
            let slot = WindowSlot(axis: .horizontal, position: position, span: .third)
            guard let expected = WindowLayout.target(slot: slot, on: screen, gap: 0) else { continue }
            rows.append(
                await press(
                    .firstThird,
                    on: target,
                    mover: mover,
                    gap: 0,
                    expecting: expected,
                    name: "firstThird cycle \(position.rawValue)"
                )
            )
        }

        // Larger and smaller, around the centre.
        mover.resetCycle()
        if let current = target.refreshed()?.frame,
           let larger = ResizeStep.larger(frame: current, in: screen.visibleFrame) {
            rows.append(await press(.larger, on: target, mover: mover, gap: 0, expecting: larger))
        }
        if let current = target.refreshed()?.frame,
           let smaller = ResizeStep.smaller(frame: current, in: screen.visibleFrame) {
            rows.append(await press(.smaller, on: target, mover: mover, gap: 0, expecting: smaller))
        }

        // Restore: back to where the probe started, before the first press.
        rows.append(await press(.restore, on: target, mover: mover, gap: 0, expecting: origin))

        // The minimum size. A third of this screen with a 40 pt gap is
        // narrower than the probe's 500 pt minimum, so the probe keeps its
        // width and the mover pins it flush to the edge the layout asked for.
        mover.resetCycle()
        rows.append(await clamp(.firstThird, on: target, mover: mover, screen: screen, edge: .leading))
        mover.resetCycle()
        rows.append(await clamp(.lastThird, on: target, mover: mover, screen: screen, edge: .trailing))

        rows.append(contentsOf: await hotKeys(on: target, screen: screen, services: services))

        return rows
    }

    // MARK: - The shortcuts

    /// Every chord of the Rectangle set, from the registration to the window.
    ///
    /// Two facts per binding. First, `RegisterEventHotKey` answered `noErr`,
    /// which is the claim itself. Second, the Carbon `kEventHotKeyPressed`
    /// event of that claim, sent to the application event target the way the
    /// system sends it, arrives in the handler and moves the window.
    ///
    /// What it does not prove: that macOS delivers the physical chord to this
    /// app. Only a finger on the keyboard shows that, and no test may press a
    /// key on somebody's machine. The `--window-selftest` run posts no input
    /// event at all.
    ///
    /// Nothing but the probe is ever touched: the controller's hot key target
    /// is pinned to the probe window for the whole section, so the frontmost
    /// window - the user's - is not even read.
    private static func hotKeys(
        on target: WindowTarget,
        screen: ScreenFrame,
        services: AppServices
    ) async -> [Row] {
        let windows = services.windows
        let mover = windows.mover
        windows.hotKeyTarget = { target.refreshed() ?? target }
        defer { windows.hotKeyTarget = nil }
        // The set under test, for this run only: the settings file keeps
        // whatever the user chose.
        windows.overrideChoice(.rectangle)

        var rows: [Row] = []
        for binding in ShortcutSet.rectangle.bindings {
            let action = binding.action
            let state = windows.registrations[action]
            guard state == .registered else {
                rows.append(
                    Row(
                        name: "chord \(action.rawValue)",
                        passed: false,
                        expected: "\(binding.display) registered",
                        actual: state?.summary ?? "no answer"
                    )
                )
                continue
            }

            mover.resetCycle()
            let before = target.refreshed()?.frame
            let expected = WindowLayout.target(
                action: action,
                on: screen,
                current: before,
                gap: windows.gap
            )
            let status = windows.dispatchHotKeyForSelfTest(action)
            try? await Task.sleep(for: settle)
            let dispatched = windows.lastHotKeyAction == action
            let actual = target.refreshed()?.frame

            // A placement says where the window has to be. The rest - restore,
            // larger, smaller, the display moves - only has to reach the
            // handler: what they do depends on the history or on a second
            // display this Mac may not have.
            if let expected, let actual {
                rows.append(
                    Row(
                        name: "chord \(action.rawValue)",
                        passed: dispatched && status == noErr && matches(actual, expected),
                        expected: "\(binding.display) -> \(text(expected))",
                        actual: dispatched ? text(actual) : "handler not reached"
                    )
                )
            } else {
                rows.append(
                    Row(
                        name: "chord \(action.rawValue)",
                        passed: dispatched && status == noErr,
                        expected: "\(binding.display) reaches the handler",
                        actual: dispatched ? "handled, status \(status ?? -1)" : "handler not reached"
                    )
                )
            }
        }

        // The two actions Rectangle ships without a chord.
        for action in ShortcutSet.unbound.sorted(by: { $0.rawValue < $1.rawValue }) {
            rows.append(
                Row(
                    name: "chord \(action.rawValue)",
                    passed: ShortcutSet.rectangle.binding(for: action) == nil,
                    expected: "no default chord",
                    actual: ShortcutSet.rectangle.binding(for: action)?.display ?? "none"
                )
            )
        }
        return rows
    }

    // MARK: - One press

    private static func press(
        _ action: WindowAction,
        on target: WindowTarget,
        mover: AXWindowMover,
        gap: CGFloat,
        expecting expected: CGRect,
        name: String? = nil
    ) async -> Row {
        let result = mover.apply(action, to: target, gap: gap)
        try? await Task.sleep(for: settle)
        let actual = target.refreshed()?.frame
        let label = name ?? action.rawValue
        guard let actual else {
            return Row(name: label, passed: false, expected: text(expected), actual: "no window")
        }
        if case .refused(let reason) = result {
            return Row(name: label, passed: false, expected: text(expected), actual: reason.rawValue)
        }
        return Row(
            name: label,
            passed: matches(actual, expected),
            expected: text(expected),
            actual: text(actual)
        )
    }

    private enum Edge {
        case leading
        case trailing
    }

    /// The window that refuses to shrink stays flush with the edge it was sent
    /// to, at its own width.
    private static func clamp(
        _ action: WindowAction,
        on target: WindowTarget,
        mover: AXWindowMover,
        screen: ScreenFrame,
        edge: Edge
    ) async -> Row {
        let gap: CGFloat = 40
        let name = "\(action.rawValue) under the minimum width"
        guard let intended = WindowLayout.target(action: action, on: screen, gap: gap) else {
            return Row(name: name, passed: false, expected: "a third", actual: "no layout")
        }
        _ = mover.apply(action, to: target, gap: gap)
        try? await Task.sleep(for: settle)
        guard let actual = target.refreshed()?.frame else {
            return Row(name: name, passed: false, expected: text(intended), actual: "no window")
        }
        let refused = actual.width > intended.width + tolerance
        let flush = edge == .leading
            ? abs(actual.minX - intended.minX) <= tolerance
            : abs(actual.maxX - intended.maxX) <= tolerance
        let expectation = edge == .leading
            ? "wider than \(Int(intended.width)) and flush at x \(Int(intended.minX))"
            : "wider than \(Int(intended.width)) and flush at maxX \(Int(intended.maxX))"
        return Row(
            name: name,
            passed: refused && flush,
            expected: expectation,
            actual: text(actual)
        )
    }

    // MARK: - The probe

    private static func launch(
        probePath: String,
        title: String,
        frame: CGRect
    ) async -> NSRunningApplication? {
        let url = URL(filePath: probePath, directoryHint: .isDirectory)
        let configuration = NSWorkspace.OpenConfiguration()
        // Never the front: the user is working on this machine.
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [
            "--title", title,
            "--frame", "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))",
        ]
        return try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private static func findWindow(pid: pid_t, title: String) async -> WindowTarget? {
        for _ in 0..<50 {
            if let window = WindowTarget.windows(of: pid).first(where: { $0.title == title }) {
                return window
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    // MARK: - The table

    private static func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func text(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) \(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }

    private static func write(rows: [Row], to directory: String?) {
        let failures = rows.filter { !$0.passed }.count
        let width = max(rows.map(\.name.count).max() ?? 4, 4)
        var lines = ["| \("case".padded(width)) | result | expected              | actual                |"]
        lines.append("|-\(String(repeating: "-", count: width))-|--------|-----------------------|-----------------------|")
        for row in rows {
            lines.append(
                "| \(row.name.padded(width)) | \(row.passed ? "PASS  " : "FAIL  ") "
                    + "| \(row.expected.padded(21)) | \(row.actual.padded(21)) |"
            )
        }
        lines.append("")
        lines.append(
            """
            The chord rows drive the Carbon handler that RegisterEventHotKey feeds, \
            against the probe window. They prove the claim, the dispatch and the move. \
            They do not prove that macOS delivers a physical key press to this app: \
            no key is pressed, and that stays a user check.
            """
        )
        lines.append("")
        lines.append("\(rows.count - failures)/\(rows.count) passed")
        lines.append(failures == 0 ? "WINDOW SELFTEST: PASS" : "WINDOW SELFTEST: FAIL")
        let text = lines.joined(separator: "\n")

        AppLog.windows.notice("window selftest: \(failures == 0 ? "PASS" : "FAIL", privacy: .public)")
        let base = URL(
            filePath: directory ?? NSTemporaryDirectory(),
            directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? text.write(
            to: base.appending(path: "window-selftest.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}

private extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
