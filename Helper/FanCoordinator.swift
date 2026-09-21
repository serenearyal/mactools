import Darwin
import Foundation
import Synchronization
import os

import FanControl
import HelperProtocol

/// The fan governor with a life of its own: a 2 s timer, the client count, the
/// power transitions and the signals.
///
/// The four ways every fan comes back to Auto meet here.
/// 1. The last XPC client goes away. A curve therefore needs the app running,
///    which is also how Macs Fan Control behaves, and it is what makes
///    `kill -9` of the app safe.
/// 2. SIGTERM, SIGINT or SIGHUP, plus `atexit` for every other way out.
///    `HelperService` owns those handlers now, because the sleep setting has
///    to come off in the same breath and two sets of handlers on one signal
///    would race to `exit(0)`; the two entry points it calls are here.
/// 3. Unconditionally at start, before the listener accepts anything.
/// 4. On the way into sleep; the held modes are written again on wake.
///
/// Concurrency: one serial queue owns every hardware call. The timer fires on
/// it, and every XPC method hops onto it, so the SMC sees one caller.
final class FanCoordinator: Sendable {
    private let governor: FanGovernor
    private let queue = DispatchQueue(label: "\(HelperConstants.helperBundleIdentifier).fans")
    private let timer = Mutex<DispatchSourceTimer?>(nil)
    private let clients = Mutex(FanClientRegistry())
    private let power = Mutex(FanPowerPolicy())
    private let nextToken = Mutex<UInt64>(0)
    private let powerWatcher = PowerWatcher()
    private let log = HelperLog.fans

    init(hardware: any FanHardware) {
        governor = FanGovernor(hardware: hardware)
    }

    // MARK: - Start and stop

    /// Guarantee 3. Called before the listener resumes, so a helper that was
    /// killed mid-curve cannot leave a fan forced across a restart.
    func startWithAutoRestore() {
        queue.sync {
            governor.restoreAllAuto()
            governor.refresh()
        }
        log.notice("fan governor ready; every fan restored to Auto")
        powerWatcher.start { [weak self] event in
            self?.handle(power: event)
        }
    }

    /// Guarantee 2, the signal path. On the fan queue, like every other
    /// hardware call, so a tick in flight cannot overlap the restore.
    func restoreAllAutoOnSignal() {
        queue.sync { governor.restoreAllAuto() }
    }

    /// Guarantee 2, the `atexit` path. No queue hop: the process is already on
    /// its way out and the queue may never run again.
    func restoreAllAutoNow() {
        governor.restoreAllAuto()
    }

    // MARK: - What the XPC methods call

    func snapshot() -> FanSnapshot {
        queue.sync {
            governor.refresh()
            return governor.snapshot()
        }
    }

    /// The reason it did not happen, or nil.
    func setMode(_ mode: FanMode, forFan index: Int) -> String? {
        let fault = queue.sync { governor.setMode(mode, forFan: index) }
        log.notice(
            "fan \(index, privacy: .public) set to \(mode.summary, privacy: .public)\(fault.map { ": \($0)" } ?? "")"
        )
        updateTimer()
        return fault
    }

    /// The reason a fan did not make it back, or nil.
    @discardableResult
    func restoreAllAuto() -> String? {
        let faults = queue.sync { () -> [FanFault] in
            governor.restoreAllAuto()
            return governor.snapshot().faults
        }
        updateTimer()
        guard faults.isEmpty else {
            let reasons = faults.map { "fan \($0.fanIndex): \($0.reason)" }.joined(separator: "; ")
            log.error("restore to Auto failed: \(reasons, privacy: .public)")
            return reasons
        }
        log.notice("every fan restored to Auto")
        return nil
    }

    // MARK: - Clients

    /// A token for one XPC connection. Never the pid: two connections from one
    /// process must count twice.
    func clientArrived() -> UInt64 {
        let token = nextToken.withLock { value -> UInt64 in
            value += 1
            return value
        }
        clients.withLock { _ = $0.add(token) }
        return token
    }

    /// Guarantee 1.
    func clientLeft(token: UInt64) {
        let wasLast = clients.withLock { $0.remove(token) }
        guard wasLast else { return }
        log.notice("the last client is gone; restoring every fan to Auto")
        restoreAllAuto()
    }

    // MARK: - Power

    private func handle(power event: PowerWatcher.Event) {
        let hasMode = !governor.desiredModes.isEmpty
        let action = self.power.withLock { policy in
            switch event {
            case .willSleep: policy.willSleep(hasDesiredMode: hasMode)
            case .hasPoweredOn: policy.hasPoweredOn(hasDesiredMode: hasMode)
            }
        }
        switch action {
        case .restoreAuto:
            // The wishes are kept, so the wake path can put them back.
            log.notice("sleeping: every fan to Auto")
            queue.sync { governor.suspend() }
            updateTimer()
        case .reapplyDesired:
            log.notice("awake: writing the held fan modes again")
            queue.sync { governor.reapplyDesired() }
            updateTimer()
        case .nothing:
            break
        }
    }

    // MARK: - The timer

    /// The loop runs only while a fan is not in Auto, so an idle machine pays
    /// nothing at all for fan control.
    private func updateTimer() {
        let wanted = governor.isActive
        timer.withLock { current in
            if wanted, current == nil {
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(
                    deadline: .now() + Fans.tickSeconds,
                    repeating: Fans.tickSeconds,
                    leeway: .milliseconds(200)
                )
                source.setEventHandler { [weak self] in self?.governor.tick() }
                source.resume()
                current = source
            } else if !wanted, let source = current {
                source.cancel()
                current = nil
            }
        }
    }
}
