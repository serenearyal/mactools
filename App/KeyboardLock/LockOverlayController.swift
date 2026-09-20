import AppKit
import SwiftUI

/// One borderless window per screen, above everything else.
///
/// The windows are rebuilt when the screen layout changes, so plugging a
/// display in while the keyboard is locked cannot leave a screen uncovered.
@MainActor
final class LockOverlayController {
    private var windows: [NSWindow] = []
    private var startedAt = Date()
    private var until = Date()
    private var onUnlock: (() -> Void)?
    private var screenObserver: NSObjectProtocol?

    /// For the debug capture path, which has to name a window to grab.
    var windowNumbers: [Int] { windows.map(\.windowNumber) }
    var isVisible: Bool { !windows.isEmpty }

    func show(startedAt: Date, until: Date, onUnlock: @escaping () -> Void) {
        self.startedAt = startedAt
        self.until = until
        self.onUnlock = onUnlock
        build()

        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.build()
            }
        }
    }

    func hide() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows = []
        onUnlock = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    private func build() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows = NSScreen.screens.map { screen in
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.setFrame(screen.frame, display: true)
            // Above the menu bar and above a full-screen app, and present on
            // every space so switching space with the mouse cannot escape it.
            window.level = .screenSaver
            window.collectionBehavior = [
                .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
            ]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(
                rootView: LockOverlayView(
                    startedAt: startedAt,
                    until: until,
                    onUnlock: { [weak self] in self?.onUnlock?() }
                )
            )
            return window
        }

        // The screen with the pointer gets the key window, so the hold button
        // reacts to the first press instead of to the one after the focus.
        let pointer = NSEvent.mouseLocation
        for window in windows {
            window.orderFrontRegardless()
            if window.frame.contains(pointer) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        NSApp.activate()
    }
}

/// A borderless window refuses the key status by default, and without it the
/// hold button would never see a press.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
