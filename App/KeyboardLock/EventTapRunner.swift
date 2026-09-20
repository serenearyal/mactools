import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Why a lock could not start.
enum EventTapFailure: Error, Equatable {
    case notPermitted
    case tapCreationFailed
}

/// Owns the event tap, the thread its run loop lives on and the watchdog that
/// keeps it enabled.
///
/// Nothing here runs on the main actor, on purpose. A tap has to answer every
/// event inside the tap timeout, and the main thread of a SwiftUI app is busy
/// drawing; hanging system input on it would stall the keyboard for the whole
/// session. The run loop therefore lives on a thread this class owns and uses
/// for nothing else.
///
/// `@unchecked Sendable`: the mutable state is a handful of CoreFoundation
/// references behind `lock`, which the tap thread, the watchdog queue and the
/// main thread all take.
final class EventTapRunner: @unchecked Sendable {
    /// Called from the tap thread when the Escape chord completes.
    private let onChord: @Sendable () -> Void
    private let log = Logger(subsystem: "com.serenearyal.vent", category: "lock")

    private let lock = NSLock()
    private var machPort: CFMachPort?
    private var runLoop: CFRunLoop?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var stopping = false
    private var chord = UnlockChord()

    private let watchdogQueue = DispatchQueue(label: "com.serenearyal.vent.lock.watchdog")
    private var watchdog: DispatchSourceTimer?
    private static let watchdogInterval: TimeInterval = 2

    init(onChord: @escaping @Sendable () -> Void) {
        self.onChord = onChord
    }

    // MARK: - Lifecycle

    /// Creates the tap on a new thread and waits for the answer. The wait is
    /// bounded: a tap is created in microseconds, and a hang here would be a
    /// hang of the whole app.
    func start() throws(EventTapFailure) {
        guard CGPreflightListenEventAccess(), AXIsProcessTrusted() else {
            throw EventTapFailure.notPermitted
        }

        let ready = DispatchSemaphore(value: 0)
        let created = OSAllocatedUnfairLock(initialState: false)
        let thread = Thread { [weak self] in
            guard let self else { return }
            created.withLock { $0 = install() }
            ready.signal()
            // `CFRunLoopRun` returns when the source is removed; the flag is
            // the only thing that decides whether the thread is done.
            while !isStopping() {
                CFRunLoopRunInMode(.defaultMode, 60, false)
            }
        }
        thread.name = "com.serenearyal.vent.lock"
        // Above the default so a loaded machine still answers the tap in time,
        // below the real-time bands the system uses for audio.
        thread.qualityOfService = .userInteractive
        lock.withLock { self.thread = thread }
        thread.start()

        guard ready.wait(timeout: .now() + 2) == .success, created.withLock({ $0 }) else {
            stop()
            throw EventTapFailure.tapCreationFailed
        }
        startWatchdog()
        log.notice("keyboard lock engaged")
    }

    /// Safe from any thread and safe to call twice. The tap is disabled first
    /// and synchronously: from that instant the keyboard works again, even if
    /// the rest of the teardown has to wait for a thread.
    func stop() {
        let (port, source, runLoop, thread) = lock.withLock {
            stopping = true
            let values = (machPort, self.source, self.runLoop, self.thread)
            machPort = nil
            self.source = nil
            self.runLoop = nil
            self.thread = nil
            return values
        }
        watchdog?.cancel()
        watchdog = nil

        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        if thread != nil {
            log.notice("keyboard lock released")
        }
    }

    /// The tap answers events and has not been disabled behind our back.
    var isEnabled: Bool {
        guard let port = lock.withLock({ machPort }) else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    // MARK: - Tap thread

    private func install() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let runner = Unmanaged<EventTapRunner>.fromOpaque(userInfo).takeUnretainedValue()
            return runner.handle(type: type, event: event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: LockEventMask.value,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("tap creation refused, permission or secure input")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        lock.withLock {
            machPort = port
            self.source = source
            self.runLoop = runLoop
            chord = UnlockChord()
        }
        return true
    }

    /// The whole of the work the tap does per event. It stays short: every
    /// keystroke of the session waits behind it.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switches a tap off when it is too slow or when the
            // user asks for it. Neither may leave the keyboard half locked.
            if let port = lock.withLock({ machPort }) {
                CGEvent.tapEnable(tap: port, enable: true)
                log.notice("tap re-enabled after \(type.rawValue, privacy: .public)")
            }
            return nil
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == UnlockChord.escapeKeyCode,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                registerEscape()
            }
            return nil
        case .keyUp, .flagsChanged:
            return nil
        default:
            guard type.rawValue == LockEventMask.systemDefinedType else {
                return Unmanaged.passUnretained(event)
            }
            // `NSEvent` is the only reader of the compound subtype, and it is
            // not main-actor isolated, so the tap thread may build one.
            let subtype = NSEvent(cgEvent: event)?.subtype.rawValue ?? 0
            return LockEventMask.swallowsSystemDefined(subtype: Int(subtype))
                ? nil
                : Unmanaged.passUnretained(event)
        }
    }

    private func registerEscape() {
        let now = ProcessInfo.processInfo.systemUptime
        let complete = lock.withLock { chord.registerEscape(at: now) }
        guard complete else { return }
        log.notice("escape chord completed")
        onChord()
    }

    private func isStopping() -> Bool {
        lock.withLock { stopping }
    }

    // MARK: - Watchdog

    /// Every 2 s, on a queue of its own: a tap that the system switched off
    /// while no event was flowing would otherwise stay off silently.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(
            deadline: .now() + EventTapRunner.watchdogInterval,
            repeating: EventTapRunner.watchdogInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self, let port = lock.withLock({ machPort }) else { return }
            guard !CGEvent.tapIsEnabled(tap: port) else { return }
            CGEvent.tapEnable(tap: port, enable: true)
            log.error("watchdog re-enabled the tap")
        }
        watchdog = timer
        timer.resume()
    }
}
