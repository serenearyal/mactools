import Foundation
import IOKit.ps

/// What the battery and the thermal sensor say, as one value.
///
/// One reading feeds three things: the "battery 74 % on power" clause of a
/// report, the Keep Awake guard, and the line the Keep Awake tab shows when the
/// guard has fired. They must not disagree, so they share this.
///
/// Not "PowerReading": `SMCKit` already has one of those, and it is a watt
/// figure off a rail, which is a different thing entirely.
struct PowerStatus: Equatable, Sendable {
    /// Nil on a Mac with no battery, and on one whose charge did not read.
    var percent: Int?
    /// False on a desk Mac and on a laptop that is plugged in.
    var onBattery = false
    var thermal: ProcessInfo.ThermalState = .nominal

    /// A Mac with no battery can never trip the charge guard.
    var hasBattery: Bool { percent != nil }
}

/// The battery, through `IOPSCopyPowerSourcesInfo`.
///
/// Read only, and cheap: one CF round trip, about 200 us. There is no polling
/// anywhere - `PowerSourceMonitor` is woken by the system instead.
enum PowerSourceReader {
    static func read() -> PowerStatus {
        var reading = PowerStatus(thermal: ProcessInfo.processInfo.thermalState)
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return reading }
        // "Battery Power", "AC Power" or "UPS Power". The string is the one
        // `pmset` prints, and it is the only source that is right while a
        // laptop charges: a charging battery is not on battery power.
        if let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String? {
            reading.onBattery = type == kIOPMBatteryPowerKey
        }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return reading }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                description[kIOPSIsPresentKey] as? Bool == true,
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            // "Current Capacity" is a percentage for an internal battery, and
            // "Max Capacity" is 100 on every Mac since Big Sur. The division
            // covers the older shape anyway, and costs nothing.
            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
            let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
            guard let current, let maximum, maximum > 0 else { continue }
            reading.percent = Int((current / maximum * 100).rounded())
            break
        }
        return reading
    }
}

/// A push notification whenever the power source changes.
///
/// `IOPSNotificationCreateRunLoopSource` fires on the change itself: a plug, an
/// unplug, and every percent the charge moves. Polling a battery that drops one
/// percent every four minutes would be a wakeup for nothing.
@MainActor
final class PowerSourceMonitor {
    private var source: CFRunLoopSource?
    private var thermalObserver: NSObjectProtocol?
    private let onChange: (PowerStatus) -> Void

    init(onChange: @escaping (PowerStatus) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard source == nil else { return }
        let box = Unmanaged.passRetained(Box(self)).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { box.monitor?.fire() }
        }, box)?.takeRetainedValue() else {
            Unmanaged<Box>.fromOpaque(box).release()
            return
        }
        source = created
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .defaultMode)

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            self.source = nil
        }
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
    }

    private func fire() {
        onChange(PowerSourceReader.read())
    }

    /// The C callback takes a raw pointer, and a weak reference cannot be one.
    /// The box is what is retained; it holds the monitor weakly, so a released
    /// monitor makes the callback a no-op instead of a crash.
    private final class Box {
        weak var monitor: PowerSourceMonitor?
        init(_ monitor: PowerSourceMonitor) { self.monitor = monitor }
    }
}
