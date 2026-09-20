import AppKit
import Carbon.HIToolbox
import Foundation
import WindowKit

/// What happened when one chord was claimed.
enum HotKeyRegistration: Equatable {
    case registered
    /// Another app holds this chord. Rectangle holds ⌃⌥← on this machine.
    case taken
    case failed(OSStatus)
    /// The user switched this action off, so nothing was claimed.
    case off

    var isRegistered: Bool { self == .registered }

    var summary: String {
        switch self {
        case .registered: "registered"
        case .taken: "taken"
        case .failed(let status): "failed(\(status))"
        case .off: "off"
        }
    }
}

/// The global shortcuts.
///
/// Carbon, not an event tap. `RegisterEventHotKey` needs no permission at all,
/// costs nothing per keystroke, tells us when another app already owns a chord
/// and is what Rectangle itself uses - so "taken by Rectangle" is a fact the
/// API hands over rather than a guess.
///
/// Everything here is main-actor. The Carbon handler is installed on the
/// application event target, which is drained by the main run loop, so the
/// `@convention(c)` callback is already on the main thread and
/// `MainActor.assumeIsolated` states that rather than hopping.
@MainActor
final class HotKeyCenter {
    /// Carbon's own "somebody else has this one".
    static let alreadyTakenStatus: OSStatus = -9878
    /// The signature of every hot key of this app: 'VntW'.
    private static let signature: OSType = 0x566E_7457

    /// Called with the action of the chord the user pressed.
    var onAction: ((WindowAction) -> Void)?

    private(set) var registrations: [WindowAction: HotKeyRegistration] = [:]
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: WindowAction] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private let log = AppLog.windows

    // No `deinit`: a Carbon reference is not `Sendable`, so a nonisolated
    // deinit may not touch one under Swift 6. The centre lives as long as the
    // app does, the quit path calls `unregisterAll`, and every claim the
    // system holds dies with the process in any case.

    // MARK: - Registration

    /// Claims every binding, in order, and reports what each one did.
    ///
    /// Always call it with the complete set: the old claims are dropped first,
    /// so a set change never leaves half of the previous set live.
    @discardableResult
    func register(_ bindings: [HotKeyBinding], disabled: Set<WindowAction> = []) -> [WindowAction: HotKeyRegistration] {
        unregisterAll()
        guard !bindings.isEmpty else { return [:] }
        installHandler()

        var results: [WindowAction: HotKeyRegistration] = [:]
        for binding in bindings {
            guard !disabled.contains(binding.action) else {
                results[binding.action] = .off
                continue
            }
            results[binding.action] = claim(binding)
        }
        registrations = results
        let taken = results.filter { $0.value == .taken }.count
        log.notice(
            "hot keys: \(results.count - taken, privacy: .public) registered, \(taken, privacy: .public) taken"
        )
        return results
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
        registrations.removeAll()
        nextID = 1
    }

    private func claim(_ binding: HotKeyBinding) -> HotKeyRegistration {
        let id = EventHotKeyID(signature: HotKeyCenter.signature, id: nextID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers.carbonFlags,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            return status == HotKeyCenter.alreadyTakenStatus ? .taken : .failed(status)
        }
        actions[nextID] = binding.action
        refs.append(ref)
        nextID += 1
        return .registered
    }

    // MARK: - The Carbon handler

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id
            )
            guard status == noErr, id.signature == HotKeyCenter.signature else {
                return OSStatus(eventNotHandledErr)
            }
            // The application event target is drained by the main run loop,
            // which is the main actor. Same pattern as the lock's event tap,
            // the other side of the one C callback boundary in this app.
            return MainActor.assumeIsolated {
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                return center.handle(id: id.id)
            }
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &type,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    private func handle(id: UInt32) -> OSStatus {
        guard let action = actions[id] else { return OSStatus(eventNotHandledErr) }
        onAction?(action)
        return noErr
    }
}
