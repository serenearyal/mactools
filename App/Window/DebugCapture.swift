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
        // The window manager, before anything else can take the front: which
        // window it would move, and what the system said about every chord.
        writeWindowStatus(services: services, to: base.appending(path: "windows-\(suffix).txt"))

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let tab = services.selectedTab.rawValue
            capture(
                window: services.windowController.attachedWindow,
                to: base.appending(path: "window-\(tab)-\(suffix).png")
            )
            captureDetail(
                services: services,
                dark: suffix == "dark",
                size: detailSize(services: services),
                to: base.appending(path: "detail-\(tab)-\(suffix).png")
            )
            // The Windows section draws the window that was in front, and the
            // render is not the popover opening, so nothing captures it for us.
            services.windows.captureTarget()
            // All three sections in one run: the popover is pure SwiftUI, so
            // it costs one `ImageRenderer` pass each and saves two launches.
            for section in PopoverSection.allCases {
                capturePopover(
                    services: services,
                    section: section,
                    dark: suffix == "dark",
                    to: base.appending(path: "popover-\(section.rawValue)-\(suffix).png")
                )
            }
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
            // The Keep Awake glyph beside the ordinary one, so the two can be
            // compared at 1x and 2x without holding the Mac awake for it.
            for scale in [CGFloat(1), CGFloat(2)] {
                captureLabel(
                    cells: cells,
                    style: .twoLine,
                    dark: suffix == "dark",
                    awake: true,
                    scale: scale,
                    to: base.appending(path: "menubar-awake-\(Int(scale))x-\(suffix).png")
                )
                captureLabel(
                    cells: cells,
                    style: .twoLine,
                    dark: suffix == "dark",
                    scale: scale,
                    to: base.appending(path: "menubar-asleep-\(Int(scale))x-\(suffix).png")
                )
            }
            if quit { NSApp.terminate(nil) }
        }
    }

    /// `--label-bench <directory>`: how long one status item label costs.
    ///
    /// The label is the only thing an idle Vent draws, so the question "is
    /// `ImageRenderer` worth replacing" is answered here rather than guessed.
    /// Every render uses a different value, which is what the menu bar really
    /// does once a second, so no cache can flatter the number.
    static func benchmarkLabel(directory: String, services: AppServices) {
        let base = URL(filePath: directory, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let style = services.settings.labelStyle
        let count = 60
        let samples = (0..<count).map { index in
            [
                MenuBarCell(metric: .cpuUsage, caption: "CPU", value: "\(10 + index % 80)%", widest: "100%"),
                MenuBarCell(
                    metric: .cpuTemperature,
                    caption: "CPU",
                    value: "\(40 + index % 50)°",
                    widest: "100°"
                ),
            ]
        }

        var rendererSeconds = 0.0
        for cells in samples {
            let start = Date.now
            let renderer = ImageRenderer(
                content: MenuBarLabelView(cells: cells, style: style, showIcon: true, awake: false)
            )
            renderer.scale = 2
            _ = renderer.nsImage
            rendererSeconds += Date.now.timeIntervalSince(start)
        }

        var directSeconds = 0.0
        for cells in samples {
            let start = Date.now
            _ = MenuBarLabelImage.image(cells: cells, style: style, showIcon: true, awake: false, scale: 2)
            directSeconds += Date.now.timeIntervalSince(start)
        }

        // The two renders of the same label at both scales, so the look can be
        // compared pixel for pixel instead of by eye. The appearance is not a
        // variant: the label is a template image, and the system tints the one
        // image for the light and the dark menu bar.
        let cells = samples[0]
        var differences: [String] = []
        for scale in [CGFloat(1), CGFloat(2)] {
            let rendered = renderedImage(cells: cells, style: style, scale: scale)
            let drawn = MenuBarLabelImage.image(
                cells: cells,
                style: style,
                showIcon: true,
                awake: false,
                scale: scale
            )
            for (name, image) in [("imagerenderer", rendered), ("direct", drawn)] {
                guard let image, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff)
                else { continue }
                write(rep, to: base.appending(path: "bench-\(name)-\(Int(scale))x.png"))
            }
            differences.append("at \(Int(scale))x: \(difference(rendered, drawn))")
        }

        let lines = [
            "renders: \(count)",
            "style: \(style.rawValue)",
            String(format: "ImageRenderer: %.3f ms per render", rendererSeconds / Double(count) * 1000),
            String(format: "direct draw:   %.3f ms per render", directSeconds / Double(count) * 1000),
            "ImageRenderer size: \(renderedImage(cells: cells, style: style, scale: 2)?.size ?? .zero)",
            "direct draw size:   \(MenuBarLabelImage.image(cells: cells, style: style, showIcon: true, awake: false, scale: 2)?.size ?? .zero)",
        ] + differences
        try? lines.joined(separator: "\n")
            .write(to: base.appending(path: "label-bench.txt"), atomically: true, encoding: .utf8)
    }

    /// How far the two renders of the same label are apart: the share of
    /// pixels whose alpha differs at all, and the worst difference of the lot.
    /// The label is a template image, so alpha is the whole picture.
    private static func difference(_ lhs: NSImage?, _ rhs: NSImage?) -> String {
        guard let lhs, let rhs,
              let left = bitmap(of: lhs), let right = bitmap(of: rhs)
        else { return "not comparable" }
        guard left.pixelsWide == right.pixelsWide, left.pixelsHigh == right.pixelsHigh else {
            return "different sizes: \(left.pixelsWide)x\(left.pixelsHigh) vs \(right.pixelsWide)x\(right.pixelsHigh)"
        }
        var differing = 0
        var worst = 0
        var total = 0
        for y in 0..<left.pixelsHigh {
            for x in 0..<left.pixelsWide {
                guard let a = left.colorAt(x: x, y: y), let b = right.colorAt(x: x, y: y) else {
                    continue
                }
                total += 1
                let delta = Int((abs(a.alphaComponent - b.alphaComponent) * 255).rounded())
                if delta > 8 { differing += 1 }
                worst = max(worst, delta)
            }
        }
        let share = total == 0 ? 0 : Double(differing) / Double(total) * 100
        return String(format: "%.1f %% of pixels differ by more than 8/255, worst %d/255", share, worst)
    }

    private static func bitmap(of image: NSImage) -> NSBitmapImageRep? {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first {
            return rep
        }
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    private static func renderedImage(
        cells: [MenuBarCell],
        style: MenuBarLabelStyle,
        scale: CGFloat
    ) -> NSImage? {
        let renderer = ImageRenderer(content: MenuBarLabelView(cells: cells, style: style))
        renderer.scale = scale
        return renderer.nsImage
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

    /// The size the detail pane really has right now: the content of the
    /// window less the sidebar and the title bar.
    ///
    /// It follows `--window-size`, so the render of a tab at the 760 x 480
    /// minimum is the layout at that minimum - and it is the only way to see
    /// it at all while the screen is locked, where no window can be
    /// photographed.
    private static func detailSize(services: AppServices) -> CGSize {
        guard let content = services.windowController.attachedWindow?.contentView?.bounds.size,
              content.width > 300, content.height > 200
        else { return CGSize(width: 708, height: 572) }
        return CGSize(width: content.width - Layout.sidebarWidth, height: content.height - 28)
    }

    /// The detail pane on its own, drawn by `ImageRenderer` at the size it has
    /// in the window this run opened.
    private static func captureDetail(
        services: AppServices,
        dark: Bool,
        size: CGSize,
        to url: URL
    ) {
        // A macOS `ScrollView`, `Table` and `List` are AppKit views, and
        // `ImageRenderer` draws nothing for them. The overview has a
        // scroll-free form for exactly this reason.
        let content = Group {
            if services.selectedTab == .overview {
                VStack(spacing: Layout.cardSpacing) {
                    if services.setup.isVisible {
                        SetupChecklistCard(checklist: services.setup)
                    }
                    // The same rule the tab itself follows, so a render at the
                    // 760 pt minimum shows the single column that a 760 pt
                    // window really draws.
                    OverviewCards(
                        store: services.store,
                        settings: services.settings,
                        twoColumns: size.width >= Layout.twoColumnWidth
                    )
                }
                .padding(Layout.cardSpacing)
            } else if services.selectedTab == .windows {
                WindowsContent(
                    controller: services.windows,
                    settings: services.settings,
                    scrolls: false
                )
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
        .frame(width: size.width, height: size.height)
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
    private static func capturePopover(
        services: AppServices,
        section: PopoverSection,
        dark: Bool,
        to url: URL
    ) {
        let content = MenuBarPopoverView(services: services, forcedSection: section)
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
        // The Keep Awake glyph must not change the width of the status item.
        let awakeWidth = ImageRenderer(
            content: MenuBarLabelView(cells: cells, style: services.settings.labelStyle, awake: true)
        ).nsImage?.size.width ?? 0
        let lines = labelWidths + [
            "label icon only: \(String(format: "%.1f", iconOnlyWidth)) pt",
            "label awake: \(String(format: "%.1f", awakeWidth)) pt",
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
            "popover section: \(services.popoverSection.rawValue)",
            "menu bar tip shown: \(services.statusItemController?.isTipShown ?? false)",
            "menu bar tip window number: \(services.statusItemController?.tipWindowNumber ?? 0)",
            "menu bar tip seen: \(services.settings.menuBarTipShown)",
            "status item on screen: \(services.statusItemController?.isItemOnScreen ?? false)",
            "status item label on screen: \(services.statusItemController?.isLabelOnScreen ?? false)",
            "menu bar label samples: \(services.demand.menuBarShowsMetrics)",
            "show dock icon: \(services.settings.showDockIcon)",
            // What the stores were last asked for, and by whom.
            "sampling demand: \(services.demand.summary)",
            "metrics request: \(metricsRequest(services).summary)",
            "window tab request: \(SamplingPlan.windowRequest(tab: services.selectedTab, showsUnlabelledSensors: services.settings.showUnlabelledSensors).summary)",
            "popover section request: \(SamplingPlan.popoverRequest(section: services.popoverSection).summary)",
            "samples processes: \(SamplingPlan.samplesProcesses(services.demand))",
            "polls fans: \(SamplingPlan.pollsFans(services.demand))",
            // R2, R3 and R4, in one block.
            "keep awake: \(services.keepAwake.debugSummary)",
            "keep awake badge: \(services.keepAwake.badgeText ?? "none")",
            "keep awake reason: \(services.keepAwake.reason ?? "none")",
            "keep awake assertions: \(services.keepAwake.assertions.count)",
            "sleep disabled: \(services.keepAwake.sleepDisabled.map(String.init) ?? "unread")",
            "backlight: \(services.backlight.debugSummary)",
            "backlight available: \(services.backlight.isAvailable)",
            "report can files: \(services.reports.canReportFiles)",
            "window number: \(window?.windowNumber ?? 0)",
            // The tab title belongs in the title bar of every tab. A `Form`
            // tab used to leave it empty, so a capture run checks the string
            // and the visibility rather than the pixels - and can do it with
            // the screen locked, where no screenshot is possible at all.
            "window title: \(window?.title ?? "none")",
            "window title visible: \(window?.titleVisibility == .visible)",
            "window titlebar transparent: \(window?.titlebarAppearsTransparent ?? false)",
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

    /// What one pass really reads, for the demand on screen at this moment.
    private static func metricsRequest(_ services: AppServices) -> SampleRequest {
        SamplingPlan.metricsRequest(
            demand: services.demand,
            menuBarMetrics: services.settings.menuBarMetrics,
            chosenSensorScope: .labelled,
            showsUnlabelledSensors: services.settings.showUnlabelledSensors
        )
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

    /// What the window manager sees: the window it would move, the displays,
    /// the other managers that are running and the result of every chord.
    ///
    /// The chord list is the point. A registration cannot be checked by
    /// pressing keys on somebody's machine, and `RegisterEventHotKey` reports
    /// "taken" for a chord another app owns, so this file is the proof.
    private static func writeWindowStatus(services: AppServices, to url: URL) {
        let windows = services.windows
        windows.captureTarget()
        let target = windows.target
        let conflicts = windows.conflicts
            .map { "\($0.label) pid \($0.pid)" }
            .joined(separator: " | ")
        var lines = [
            "AXIsProcessTrusted: \(windows.accessibilityGranted)",
            "window id lookup: \(AX.hasWindowIDLookup)",
            "target: \(target?.label ?? "none")",
            "target pid: \(target?.pid ?? 0)",
            "target frame: \(target.map { "\($0.frame)" } ?? "none")",
            "target subrole: \(target?.subrole ?? "none")",
            "target settable: position \(target?.isPositionSettable ?? false), size \(target?.isSizeSettable ?? false)",
            "target refusal: \(target?.refusal?.rawValue ?? "none")",
            "target display: \(target?.displayName ?? "none")",
            "status: \(windows.status ?? "none")",
            "screens: \(ScreenList.count)",
            "gap: \(Int(windows.gap)) pt",
            "eui workaround: \(services.settings.windows.enhancedUserInterfaceWorkaround)",
            "reactivates after tile: \(services.settings.windows.reactivatesAfterTile)",
            "window managers running: \(conflicts.isEmpty ? "none" : conflicts)",
            "conflict banner: \(windows.showsConflictBanner)",
        ]
        lines.append(contentsOf: windows.registrationReport)
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// The template label on the background the menu bar would give it.
    private static func captureLabel(
        cells: [MenuBarCell],
        style: MenuBarLabelStyle,
        dark: Bool,
        awake: Bool = false,
        scale: CGFloat = 2,
        to url: URL
    ) {
        let renderer = ImageRenderer(
            content: MenuBarLabelView(cells: cells, style: style, awake: awake)
        )
        renderer.scale = scale
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
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
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
