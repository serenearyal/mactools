import BacklightKit
import Foundation
import Observation

/// The keyboard backlight, as the views see it.
///
/// A thin shell over `BacklightEngine`: this owns the two timers and republishes
/// the engine's state; every rule about clamping, snapping, debouncing and
/// availability lives in the engine, which is plain and tested.
///
/// The poll runs at 1 Hz and only while a slider is on screen, wired through
/// the same demand the metric samplers follow, so a closed popover and a window
/// on another tab cost nothing at all.
@MainActor
@Observable
final class KeyboardBacklightController {
    private(set) var level: Double = 0
    private(set) var reading = BacklightReading()
    private(set) var availability: BacklightAvailability = .unavailable(reason: .frameworkMissing)

    @ObservationIgnored private let engine: BacklightEngine
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var flushTimer: Timer?
    @ObservationIgnored private var demand = SamplingDemand()
    /// Set while the Backlight tab or the Tools section is on screen.
    @ObservationIgnored private var observingStarted = false

    /// One second: the framework reports whole rungs, and the ambient sensor
    /// moves the level over seconds, not frames.
    private static let pollInterval: TimeInterval = 1

    init(forcedUnavailable: Bool = BacklightDebug.isForcedUnavailable) {
        engine = BacklightEngine(
            client: KeyboardBacklightClient(),
            forcedUnavailable: forcedUnavailable
        )
        publish()
        AppLog.app.notice("backlight: \(self.engine.summary, privacy: .public)")
    }

    var isAvailable: Bool { availability.isAvailable }

    /// "6%", fixed width by the caller.
    var percentText: String { BacklightScale.percentText(level) }

    var isAuto: Bool { reading.isAuto }

    // MARK: - Cadence

    /// Only a view with a slider in it asks for a poll. The Tools section of
    /// the popover and the Backlight tab are the two; every other tab and a
    /// closed popover ask for nothing.
    func setDemand(_ demand: SamplingDemand) {
        guard self.demand != demand else { return }
        self.demand = demand
        updatePolling()
    }

    private var wantsLiveValue: Bool {
        guard isAvailable else { return false }
        return demand.showsTab(.backlight) || demand.showsPopoverSection(.tools)
    }

    private func updatePolling() {
        let wanted = wantsLiveValue
        if wanted, pollTimer == nil {
            // The push path first: if the framework honours one of its own key
            // names, the timer below is a belt to its braces and costs one
            // cheap read a second while a slider is visible.
            if !observingStarted {
                observingStarted = engine.startObserving { [weak self] in
                    self?.engine.poll()
                    self?.publish()
                }
            }
            engine.poll()
            publish()
            let timer = Timer.scheduledTimer(
                withTimeInterval: KeyboardBacklightController.pollInterval,
                repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.engine.poll()
                    self?.publish()
                }
            }
            timer.tolerance = KeyboardBacklightController.pollInterval / 5
            pollTimer = timer
        } else if !wanted, pollTimer != nil {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: - The slider

    func slide(to value: Double) {
        if engine.slide(to: value) { scheduleFlush() }
        publish()
    }

    /// The mouse went up: snap to the ladder and write once more.
    func commit() {
        flushTimer?.invalidate()
        flushTimer = nil
        engine.commit()
        publish()
    }

    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: BacklightEngine.writeInterval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushTimer = nil
                self?.engine.flush()
                self?.publish()
            }
        }
        flushTimer = timer
    }

    /// The Auto chip and the "Turn off Auto" button. The only path in the app
    /// that writes the ambient setting, and both of them are an explicit click.
    func setAuto(_ enabled: Bool) {
        engine.setAuto(enabled)
        publish()
    }

    func refresh() {
        engine.poll()
        publish()
    }

    // MARK: - Debug

    var debugSummary: String { engine.summary }

    /// `--backlight-probe`: one line in the log with everything the hardened
    /// Release build managed to read out of the private framework.
    func probe() {
        AppLog.app.notice(
            """
            backlight probe: \(self.engine.summary, privacy: .public), \
            writes \(self.engine.writeCount, privacy: .public), \
            notifications \(self.engine.observedKeys.sorted().joined(separator: ","), privacy: .public)
            """
        )
    }

    private func publish() {
        level = engine.level
        reading = engine.reading
        availability = engine.availability
    }
}

/// `--backlight-force-unavailable`, so the empty path can be photographed on a
/// Mac whose keyboard does light up.
enum BacklightDebug {
    static var isForcedUnavailable: Bool {
        CommandLine.arguments.contains("--backlight-force-unavailable")
    }
}
