import AppKit
import SwiftUI

/// Opens, hides and tracks the one main window.
///
/// The window itself belongs to the SwiftUI `Window` scene. This class keeps
/// the reference the scene hands over through `WindowAccessor`, so the status
/// item can toggle it and the store can slow down while it is hidden.
///
/// An accessory app puts a new window behind the app that was in front, so
/// every show path calls `NSApp.activate()` as well.
@MainActor
final class MainWindowController {
    static let windowID = "main"
    static let frameAutosaveName = "VentMainWindow"

    weak var store: MetricsStore?
    weak var processes: ProcessStore?

    private weak var window: NSWindow?
    private var openAction: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// Set while a show is waiting for the scene to build the window.
    private var pendingActivation = false

    /// Called by the app scene, which is the only place `openWindow` exists.
    func setOpenAction(_ action: @escaping () -> Void) {
        openAction = action
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(MainWindowController.frameAutosaveName)
        observe(window)
        if pendingActivation {
            bringToFront(window)
        } else {
            updateVisibility()
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// The window the scene created, for the self-capture debug path.
    var attachedWindow: NSWindow? { window }

    func toggle() {
        if isVisible {
            window?.orderOut(nil)
            updateVisibility()
        } else {
            show()
        }
    }

    func show(tab: MainTab? = nil) {
        if let tab { AppServices.shared.selectedTab = tab }
        if let window {
            bringToFront(window)
            return
        }
        // No window yet: the scene builds it, `attach` finishes the job. The
        // delayed retry covers the case where SwiftUI orders the window front
        // itself, after the accessor has run.
        pendingActivation = true
        openAction?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let window else { return }
            bringToFront(window)
        }
    }

    /// An accessory app has to ask for activation; without it the window
    /// appears behind the app that was in front.
    private func bringToFront(_ window: NSWindow) {
        pendingActivation = false
        NSApp.activate()
        // Belt and braces: cooperative activation can refuse `NSApp.activate`
        // when another app holds the front, and this asks the workspace
        // directly.
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        updateVisibility()
    }

    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        let names: [Notification.Name] = [
            NSWindow.willCloseNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // willClose arrives before the window is gone.
                    let closing = name == NSWindow.willCloseNotification
                    self?.updateVisibility(forcedHidden: closing)
                }
            }
        }
    }

    private func updateVisibility(forcedHidden: Bool = false) {
        let visible = !forcedHidden
            && (window?.isVisible ?? false)
            && !(window?.isMiniaturized ?? false)
            && (window?.occlusionState.contains(.visible) ?? false)
        store?.setWindowVisible(visible)
        processes?.setWindowVisible(visible)
    }
}

/// Hands the `NSWindow` of the SwiftUI scene to the controller.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { onWindow(window) }
    }
}
