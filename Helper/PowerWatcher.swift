import Foundation
import IOKit
import IOKit.pwr_mgt
import Synchronization

/// Sleep and wake, from the root power domain.
///
/// `IORegisterForSystemPower` and not `NSWorkspace`: a launch daemon has no
/// workspace notifications, and the fan modes have to be gone before the
/// machine sleeps, not after it wakes.
final class PowerWatcher: Sendable {
    enum Event: Sendable {
        case willSleep
        case hasPoweredOn
    }

    /// `IOMessage.h` builds these with a function-like macro, which Swift does
    /// not import: `iokit_common_msg(x)` is `sys_iokit | sub_iokit_common | x`,
    /// and `sys_iokit` is `0xe0000000`.
    private enum Message {
        static let canSystemSleep: UInt32 = 0xe000_0270
        static let systemWillSleep: UInt32 = 0xe000_0280
        static let systemHasPoweredOn: UInt32 = 0xe000_0300
    }

    /// The root power domain, which the sleep acknowledgement goes to. The
    /// notification port and the notifier are deliberately not kept: this
    /// watcher lives as long as the process, and IOKit owns them until it
    /// ends.
    private let rootPort = Mutex<io_connect_t>(0)
    private let handler = Mutex<(@Sendable (Event) -> Void)?>(nil)
    /// A dispatch queue and not a run loop source: the helper parks its main
    /// thread in `dispatchMain()`, where no CFRunLoop ever runs.
    private let queue = DispatchQueue(label: "com.serenearyal.mactools.helper.power")

    func start(_ onEvent: @escaping @Sendable (Event) -> Void) {
        handler.withLock { $0 = onEvent }

        var notifier: io_object_t = 0
        var port: IONotificationPortRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let root = IORegisterForSystemPower(context, &port, powerCallback, &notifier)
        guard root != MACH_PORT_NULL, let port else { return }

        IONotificationPortSetDispatchQueue(port, queue)
        rootPort.withLock { $0 = root }
        _ = notifier
    }

    /// Answers the power domain and, for a sleep, tells the handler first.
    ///
    /// The acknowledgement is what lets the machine go to sleep, so it is sent
    /// whatever the handler did.
    fileprivate func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let callback = handler.withLock { $0 }
        switch messageType {
        case Message.canSystemSleep, Message.systemWillSleep:
            // The fans have to be back under firmware control before the
            // acknowledgement, which is what lets the machine sleep.
            if messageType == Message.systemWillSleep {
                callback?(.willSleep)
            }
            let root = rootPort.withLock { $0 }
            if root != MACH_PORT_NULL {
                IOAllowPowerChange(root, Int(bitPattern: argument))
            }
        case Message.systemHasPoweredOn:
            callback?(.hasPoweredOn)
        default:
            break
        }
    }
}

/// A C callback carries its context in a pointer and nothing else.
private func powerCallback(
    context: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: UInt32,
    argument: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    Unmanaged<PowerWatcher>.fromOpaque(context).takeUnretainedValue()
        .handle(messageType: messageType, argument: argument)
}
