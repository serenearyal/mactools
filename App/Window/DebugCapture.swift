import AppKit
import SwiftUI

/// Self-capture for the UI checks of a build agent.
///
/// `screencapture` needs Screen Recording permission, which a headless run
/// does not have. An app may always draw its own views, so these paths write
/// the window and the menu bar label to PNG files with no permission at all.
///
/// Every path is off unless the matching launch argument is present:
/// `--capture <directory> [--appearance dark|light] [--capture-delay 8]
/// [--capture-quit]`.
@MainActor
enum DebugCapture {
    static func run(arguments: [String], services: AppServices) {
        if let appearance = value(of: "--appearance", in: arguments) {
            NSApp.appearance = NSAppearance(
                named: appearance == "dark" ? .darkAqua : .aqua
            )
        }
        guard let directory = value(of: "--capture", in: arguments) else { return }
        let delay = value(of: "--capture-delay", in: arguments).flatMap(Double.init) ?? 8
        let quit = arguments.contains("--capture-quit")
        let suffix = value(of: "--appearance", in: arguments) ?? "light"

        // The lock file is written at once, not after the delay: an overlay
        // preview lasts seconds, and the capturing script needs the window
        // numbers while the windows are still on screen.
        let base = URL(filePath: directory, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        writeLockStatus(services: services, to: base.appending(path: "lock-\(suffix).txt"))

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let tab = services.selectedTab.rawValue
            capture(
                window: services.windowController.attachedWindow,
                to: base.appending(path: "window-\(tab)-\(suffix).png")
            )
            captureDetail(
                services: services,
                dark: suffix == "dark",
                to: base.appending(path: "detail-\(tab)-\(suffix).png")
            )
            capturePopover(
                services: services,
                dark: suffix == "dark",
                to: base.appending(path: "popover-\(suffix).png")
            )
            writeStatus(
                services: services,
                to: base.appending(path: "status-\(tab)-\(suffix).txt")
            )
            let cells = MenuBarLabel.cells(
                snapshot: services.store.snapshot,
                settings: services.settings
            )
            for style in MenuBarLabelStyle.allCases {
                captureLabel(
                    cells: cells,
                    style: style,
                    dark: suffix == "dark",
                    to: base.appending(path: "menubar-\(style.rawValue)-\(suffix).png")
                )
            }
            // What "Show in menu bar: icon only" draws, without touching the
            // setting: no cell at all is the whole mechanism.
            captureLabel(
                cells: [],
                style: .twoLine,
                dark: suffix == "dark",
                to: base.appending(path: "menubar-icononly-\(suffix).png")
            )
            if quit { NSApp.terminate(nil) }
        }
    }

    private static func value(of name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1].lowercased()
    }

    /// The layer tree of the theme frame, title bar included. SwiftUI hosts
    /// most of its content in layers the process cannot read back, so this is
    /// a best effort; `captureDetail` is the one that shows the content.
    private static func capture(window: NSWindow?, to url: URL) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let layer = view.layer
        else { return }
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * 2),
            pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = context
            layer.render(in: context.cgContext)
        }
        NSGraphicsContext.restoreGraphicsState()
        write(rep, to: url)
    }

    /// The detail pane on its own, drawn by `ImageRenderer` at the size it
    /// has in a 900 x 600 window.
    private static func captureDetail(services: AppServices, dark: Bool, to url: URL) {
        // A macOS `ScrollView`, `Table` and `List` are AppKit views, and
        // `ImageRenderer` draws nothing for them. The overview has a
        // scroll-free form for exactly this reason.
        let content = Group {
            if services.selectedTab == .overview {
                VStack(spacing: Layout.cardSpacing) {
                    if services.setup.isVisible {
                        SetupChecklistCard(checklist: services.setup)
                    }
                    OverviewCards(store: services.store, settings: services.settings, twoColumns: true)
                }
                .padding(Layout.cardSpacing)
            } else if services.selectedTab == .fans {
                FansContent(
                    store: services.store,
                    fans: services.fans,
                    settings: services.settings,
                    helper: services.helper,
                    showSettings: {},
                    scrolls: false
                )
            } else {
                TabDetailView(tab: services.selectedTab, services: services)
            }
        }
        .frame(width: 708, height: 572)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(services)
        .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        write(NSBitmapImageRep(cgImage: image), to: url)
    }

    /// The popover content on its own, drawn by `ImageRenderer` on the
    /// material the real popover sits on.
    ///
    /// `screencapture -l <window number>` photographs the real thing, and the
    /// status file names that window; this is the path that needs no Screen
    /// Recording grant. The content is pure SwiftUI with no scroll view for
    /// exactly this reason.
    ///
    /// It is also the only way to see the popover in the appearance it does
    /// not have: the real one is built against the menu bar and follows the
    /// system, whatever `--appearance` says.
    private static func capturePopover(services: AppServices, dark: Bool, to url: URL) {
        let content = MenuBarPopoverView(services: services)
            .padding(.vertical, 2)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        write(NSBitmapImageRep(cgImage: image), to: url)
    }

    /// What the window and the app are doing, since a build agent cannot see
    /// the screen.
    private static func writeStatus(services: AppServices, to url: URL) {
        let window = services.windowController.attachedWindow
        let snapshot = services.store.snapshot
        let cells = MenuBarLabel.cells(snapshot: snapshot, settings: services.settings)
        let labelWidths = MenuBarLabelStyle.allCases.flatMap { style in
            [true, false].map { icon in
                let renderer = ImageRenderer(
                    content: MenuBarLabelView(cells: cells, style: style, showIcon: icon)
                )
                let width = renderer.nsImage?.size.width ?? 0
                return "label \(style.rawValue), icon \(icon ? "on" : "off"): \(String(format: "%.1f", width)) pt"
            }
        }
        let iconOnlyWidth = ImageRenderer(
            content: MenuBarLabelView(cells: [], style: .twoLine)
        ).nsImage?.size.width ?? 0
        let lines = labelWidths + [
            "label icon only: \(String(format: "%.1f", iconOnlyWidth)) pt",
            "menu bar content: \(services.settings.menuBarContent.rawValue)",
            "setup checklist visible: \(services.setup.isVisible)",
            "setup steps open: \(services.setup.remaining)",
            "launch at login: \(services.setup.launchAtLogin.status)",
            "full disk access: \(services.setup.hasFullDiskAccess)",
            "bundle in /Applications: \(LaunchLocationBanner.isInPlace)",
            "status item width: \(String(format: "%.1f", services.statusItemController?.itemWidth ?? 0)) pt",
            "status item image: \(services.statusItemController?.lastImageSize ?? .zero)",
            "status item window number: \(services.statusItemController?.itemWindowNumber ?? 0)",
            "popover shown: \(services.statusItemController?.isPopoverShown ?? false)",
            // `screencapture -x -o -l <n>` photographs the real popover.
            "popover window number: \(services.statusItemController?.popoverWindowNumber ?? 0)",
            "window number: \(window?.windowNumber ?? 0)",
            "app active: \(NSApp.isActive)",
            "activation policy: \(NSApp.activationPolicy().rawValue)",
            "window: \(window.map { "\($0.frame)" } ?? "none")",
            "window visible: \(window?.isVisible ?? false)",
            "window key: \(window?.isKeyWindow ?? false)",
            "window main: \(window?.isMainWindow ?? false)",
            "sensors: \(snapshot.temperatures.count)",
            "fans: \(snapshot.fans.count)",
            "helper fans: \(services.fans.fans.count)",
            "helper fan modes: \(services.fans.fans.map(\.mode.summary).joined(separator: " | "))",
            "fan interlock: \(services.fans.interlockEngaged)",
            "fan faults: \(services.fans.faults.map { "\($0.fanIndex): \($0.reason)" }.joined(separator: " | "))",
            "fan read failure: \(services.fans.failure ?? "none")",
            "fan command failure: \(services.fans.lastCommandFailure ?? "none")",
            "helper state: \(services.helper.state)",
            "helper mismatch: \(services.helper.mismatchMessage ?? "none")",
            "power rails: \(snapshot.power.count)",
            "volumes: \(snapshot.volumes.count)",
            "cpu sample: \(snapshot.cpu != nil)",
            "memory sample: \(snapshot.memory != nil)",
            "disk io sample: \(snapshot.diskIO != nil)",
            "history cpu points: \(services.store.history.cpuTotal.count)",
            "processes: \(services.processes.rows.count)",
            "processes visible: \(services.processes.visibleRows.count)",
            "processes restricted: \(services.processes.restrictedCount)",
            "processes from the helper: \(services.processes.helperRowCount)",
            "processes helper failure: \(services.processes.helperFailure ?? "none")",
            "processes top cpu: \(topProcesses(services.processes))",
            // The leak check: with nothing on screen these three stop moving.
            "metrics samples: \(services.store.sampleCount)",
            "process samples: \(services.processes.sampleCount)",
            "fan polls: \(services.fans.pollCount)",
        ]
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// The three heaviest rows, so a capture run can check the CPU column
    /// against what `top` says at the same moment.
    private static func topProcesses(_ store: ProcessStore) -> String {
        store.topByCPU
            .prefix(3)
            .map { "\($0.name) \($0.pid) \($0.cpuPercent.map { Fmt.processCPU($0) } ?? "-")" }
            .joined(separator: " | ")
    }

    /// What the keyboard lock sees of the system: the two permissions as this
    /// bundle holds them, secure input, and the overlay windows a screenshot
    /// can name.
    private static func writeLockStatus(services: AppServices, to url: URL) {
        let lock = services.keyboardLock
        let permissions = lock.refreshPermissions()
        let numbers = lock.overlayWindowNumbers.map(String.init).joined(separator: " ")
        let lines = [
            "bundle path: \(Bundle.main.bundlePath)",
            "AXIsProcessTrusted: \(permissions.accessibility)",
            "CGPreflightListenEventAccess: \(permissions.inputMonitoring)",
            "IsSecureEventInputEnabled: \(permissions.secureInputEnabled)",
            "lock state: \(lock.state)",
            "lock timeout setting: \(services.settings.lockTimeoutSeconds) s",
            "overlay windows: \(numbers.isEmpty ? "none" : numbers)",
            "screens: \(NSScreen.screens.count)",
        ]
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// The template label on the background the menu bar would give it.
    private static func captureLabel(
        cells: [MenuBarCell],
        style: MenuBarLabelStyle,
        dark: Bool,
        to url: URL
    ) {
        let renderer = ImageRenderer(content: MenuBarLabelView(cells: cells, style: style))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return }
        image.isTemplate = true

        // A template image is tinted by the control that draws it, so the
        // preview has to do the same before it composites.
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        (dark ? NSColor.white : NSColor.black).set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        let padding = CGSize(width: 16, height: 6)
        let size = CGSize(
            width: image.size.width + padding.width * 2,
            height: 24 + padding.height * 2
        )
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        tinted.draw(
            at: NSPoint(x: padding.width, y: (size.height - image.size.height) / 2),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        write(rep, to: url)
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) {
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
