import AwakeKit
import Foundation
import Testing

/// Keep Awake, driven by a clock the test chooses and a backend that records
/// instead of holding this Mac awake.
///
/// Every transition that matters is here: the timeout ending itself, the
/// battery guard taking the assertion away and giving it back, the guard
/// refusing to hand one out at all, and the rule that only the guard's own
/// release may be undone.
@Suite("Keep Awake machine")
struct KeepAwakeMachineTests {
    /// The fake power manager. It counts what the real one would have done.
    final class FakeBackend {
        private(set) var isHolding = false
        private(set) var creates: [AssertionRequest] = []
        private(set) var releases = 0
        private(set) var expiry: Date?
        /// Every lid request, in order. The helper is not called here: what
        /// matters is that the machine asks once per change and never twice.
        private(set) var lidRequests: [Bool] = []
        private(set) var lidHeld = false

        var current: AssertionRequest? { creates.last }

        func play(_ effects: [KeepAwakeMachine.Effect]) {
            for effect in effects {
                switch effect {
                case .release:
                    releases += 1
                    isHolding = false
                case .create(let request):
                    creates.append(request)
                    isHolding = true
                case .scheduleExpiry(let date):
                    expiry = date
                case .lid(let on):
                    lidRequests.append(on)
                    lidHeld = on
                }
            }
        }
    }

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func plugged(_ percent: Int = 80) -> PowerStatus {
        PowerStatus(percent: percent, onBattery: false)
    }

    private func onBattery(_ percent: Int, thermal: ProcessInfo.ThermalState = .nominal) -> PowerStatus {
        PowerStatus(percent: percent, onBattery: true, thermal: thermal)
    }

    private func machine(
        duration: KeepAwakeDuration = .indefinite,
        display: Bool = false,
        lidClose: Bool = false,
        guardOn: Bool = true,
        threshold: Int = 20,
        power: PowerStatus? = nil
    ) -> (KeepAwakeMachine, FakeBackend) {
        let options = KeepAwakeOptions(
            duration: duration,
            keepDisplayOn: display,
            lidClose: lidClose,
            batteryGuardEnabled: guardOn,
            batteryThreshold: threshold
        )
        return (KeepAwakeMachine(options: options, power: power ?? plugged()), FakeBackend())
    }

    // MARK: - The switch

    @Test("Turning it on takes one assertion and schedules nothing when indefinite")
    func indefiniteOn() {
        var (machine, backend) = machine()
        backend.play(machine.handle(.turnOn(now: start)))
        #expect(machine.state == .on(until: nil))
        #expect(backend.creates.count == 1)
        #expect(backend.releases == 0)
        #expect(backend.expiry == nil)
        #expect(backend.current?.systemSleep == true)
        #expect(backend.current?.displaySleep == false)
        #expect(backend.current?.timeoutSeconds == nil)
        #expect(backend.current?.name == "MacTools Keep Awake")
    }

    @Test("A duration becomes both the kernel timeout and the moment on screen")
    func durationOn() {
        var (machine, backend) = machine(duration: .minutes(30))
        backend.play(machine.handle(.turnOn(now: start)))
        #expect(machine.state == .on(until: start.addingTimeInterval(1_800)))
        #expect(backend.current?.timeoutSeconds == 1_800)
        #expect(backend.expiry == start.addingTimeInterval(1_800))
    }

    @Test("Keeping the display on adds the second assertion to the request")
    func displayAssertion() {
        var (machine, backend) = machine(display: true)
        backend.play(machine.handle(.turnOn(now: start)))
        #expect(backend.current?.displaySleep == true)
        #expect(backend.current?.systemSleep == true)
    }

    @Test("Turning it off releases once, and turning it off again does nothing")
    func off() {
        var (machine, backend) = machine()
        backend.play(machine.handle(.turnOn(now: start)))
        backend.play(machine.handle(.turnOff))
        #expect(machine.state == .off)
        #expect(!backend.isHolding)
        #expect(backend.releases == 1)
        backend.play(machine.handle(.turnOff))
        #expect(backend.releases == 1)
    }

    // MARK: - The timeout

    @Test("The timeout ends it without anybody pressing anything")
    func expiry() {
        var (machine, backend) = machine(duration: .minutes(1))
        backend.play(machine.handle(.turnOn(now: start)))
        backend.play(machine.handle(.expired))
        #expect(machine.state == .off)
        #expect(!backend.isHolding)
        #expect(backend.expiry == nil)
        #expect(machine.reason == nil)
    }

    @Test("A timeout that fires while it is already off changes nothing")
    func expiryWhenOff() {
        var (machine, backend) = machine(duration: .minutes(1))
        backend.play(machine.handle(.expired))
        #expect(machine.state == .off)
        #expect(backend.releases == 0)
    }

    // MARK: - Changing the options while it runs

    @Test("A new duration re-creates the assertion and restarts the countdown")
    func durationChangeWhileOn() {
        var (machine, backend) = machine(duration: .minutes(30))
        backend.play(machine.handle(.turnOn(now: start)))
        let later = start.addingTimeInterval(600)
        var options = machine.options
        options.duration = .minutes(120)
        backend.play(machine.handle(.optionsChanged(options, now: later)))
        #expect(backend.creates.count == 2)
        #expect(backend.releases == 1)
        #expect(backend.current?.timeoutSeconds == 7_200)
        // Measured from the change, not from the original start: the user
        // asked for two more hours, not for one hour fifty.
        #expect(machine.state == .on(until: later.addingTimeInterval(7_200)))
    }

    @Test("A setting the assertion does not carry leaves the countdown alone")
    func unrelatedOptionChange() {
        var (machine, backend) = machine(duration: .minutes(30))
        backend.play(machine.handle(.turnOn(now: start)))
        var options = machine.options
        options.batteryThreshold = 35
        backend.play(machine.handle(.optionsChanged(options, now: start.addingTimeInterval(60))))
        #expect(backend.creates.count == 1)
        #expect(machine.state == .on(until: start.addingTimeInterval(1_800)))
    }

    @Test("Changing the options while it is off takes no assertion")
    func optionChangeWhileOff() {
        var (machine, backend) = machine()
        var options = machine.options
        options.duration = .minutes(240)
        backend.play(machine.handle(.optionsChanged(options, now: start)))
        #expect(machine.state == .off)
        #expect(backend.creates.isEmpty)
    }

    // MARK: - The lid hold

    /// The user's own command is `sudo pmset disablesleep 1`, and this is the
    /// switch that asks the helper for the same thing.
    @Test("With the lid option on, turning Keep Awake on asks for the flag once")
    func lidHoldFollowsTheSwitch() {
        var (machine, backend) = machine(lidClose: true)
        backend.play(machine.handle(.turnOn(now: start)))
        #expect(backend.lidRequests == [true])
        #expect(machine.lidRequested)

        // Nothing the assertion carries changed, so no second request.
        var options = machine.options
        options.batteryThreshold = 35
        backend.play(machine.handle(.optionsChanged(options, now: start.addingTimeInterval(60))))
        #expect(backend.lidRequests == [true])

        backend.play(machine.handle(.turnOff))
        #expect(backend.lidRequests == [true, false])
        #expect(!machine.lidRequested)
    }

    @Test("Without the lid option, the flag is never asked for")
    func lidStaysOutOfTheWay() {
        var (machine, backend) = machine()
        backend.play(machine.handle(.turnOn(now: start)))
        backend.play(machine.handle(.turnOff))
        #expect(backend.lidRequests.isEmpty)
    }

    @Test("Switching the lid option on while Keep Awake runs takes the flag there and then")
    func lidOptionWhileOn() {
        var (machine, backend) = machine()
        backend.play(machine.handle(.turnOn(now: start)))
        #expect(backend.lidRequests.isEmpty)

        var options = machine.options
        options.lidClose = true
        backend.play(machine.handle(.optionsChanged(options, now: start.addingTimeInterval(60))))
        #expect(backend.lidRequests == [true])
        // And the assertion was not re-created for an option it does not carry.
        #expect(backend.creates.count == 1)

        options.lidClose = false
        backend.play(machine.handle(.optionsChanged(options, now: start.addingTimeInterval(120))))
        #expect(backend.lidRequests == [true, false])
    }

    @Test("The lid option alone holds nothing while Keep Awake is off")
    func lidNeedsKeepAwake() {
        var (machine, backend) = machine()
        var options = machine.options
        options.lidClose = true
        backend.play(machine.handle(.optionsChanged(options, now: start)))
        #expect(backend.lidRequests.isEmpty)
        #expect(!machine.lidRequested)
    }

    @Test("The timeout takes the flag with it")
    func lidEndsWithTheTimeout() {
        var (machine, backend) = machine(duration: .minutes(1), lidClose: true)
        backend.play(machine.handle(.turnOn(now: start)))
        backend.play(machine.handle(.expired))
        #expect(backend.lidRequests == [true, false])
        #expect(!backend.lidHeld)
    }

    @Test("The battery guard takes the flag with it, and gives it back with the assertion")
    func lidFollowsTheGuard() {
        var (machine, backend) = machine(lidClose: true, threshold: 20)
        backend.play(machine.handle(.turnOn(now: start)))
        backend.play(machine.handle(.power(onBattery(18), now: start.addingTimeInterval(60))))
        #expect(machine.state == .off)
        #expect(backend.lidRequests == [true, false])

        backend.play(machine.handle(.power(plugged(50), now: start.addingTimeInterval(120))))
        #expect(machine.state.isOn)
        #expect(backend.lidRequests == [true, false, true])
    }

    /// A closed Mac that cannot sleep cooks in a bag. The charge guard can be
    /// switched off; this one cannot, and it fires a notch earlier than the
    /// critical state that releases the assertion itself.
    @Test("A serious thermal state clears the flag while the assertion stays")
    func lidReleasesOnAHotMac() {
        var (machine, backend) = machine(lidClose: true)
        backend.play(machine.handle(.turnOn(now: start)))
        backend.play(
            machine.handle(
                .power(
                    PowerStatus(percent: 80, onBattery: false, thermal: .serious),
                    now: start.addingTimeInterval(60)
                )
            )
        )
        #expect(machine.state.isOn, "a serious thermal state is not critical: the assertion stays")
        #expect(backend.isHolding)
        #expect(backend.lidRequests == [true, false])

        // And it comes back when the Mac cools down.
        backend.play(machine.handle(.power(plugged(80), now: start.addingTimeInterval(600))))
        #expect(backend.lidRequests == [true, false, true])
    }

    @Test("A critical thermal state takes both")
    func lidReleasesWhenCritical() {
        var (machine, backend) = machine(lidClose: true)
        backend.play(machine.handle(.turnOn(now: start)))
        backend.play(
            machine.handle(
                .power(
                    PowerStatus(percent: 80, onBattery: false, thermal: .critical),
                    now: start.addingTimeInterval(60)
                )
            )
        )
        #expect(machine.state == .off)
        #expect(!backend.isHolding)
        #expect(backend.lidRequests == [true, false])
    }

    // MARK: - The battery guard

    @Test("The guard releases it below the threshold and says why")
    func guardReleases() {
        var (machine, backend) = machine(threshold: 20)
        backend.play(machine.handle(.turnOn(now: start)))
        backend.play(machine.handle(.power(onBattery(18), now: start.addingTimeInterval(60))))
        #expect(machine.state == .off)
        #expect(!backend.isHolding)
        #expect(machine.reason == "Turned off: the battery fell to 18 %.")
    }

    @Test("Plugging in gives back only what the guard took")
    func guardRestores() {
        var (machine, backend) = machine(threshold: 20)
        backend.play(machine.handle(.turnOn(now: start)))
        backend.play(machine.handle(.power(onBattery(18), now: start.addingTimeInterval(60))))
        backend.play(machine.handle(.power(plugged(18), now: start.addingTimeInterval(120))))
        #expect(machine.state.isOn)
        #expect(backend.isHolding)
        #expect(machine.reason == nil)
    }

    @Test("Plugging in does not undo a Keep Awake the user switched off")
    func userOffStaysOff() {
        var (machine, backend) = machine()
        backend.play(machine.handle(.turnOn(now: start)))
        backend.play(machine.handle(.turnOff))
        backend.play(machine.handle(.power(plugged(90), now: start.addingTimeInterval(60))))
        #expect(machine.state == .off)
        #expect(!backend.isHolding)
    }

    @Test("A charge sitting on the line does not flap")
    func hysteresis() {
        var (machine, backend) = machine(threshold: 20)
        backend.play(machine.handle(.turnOn(now: start)))
        backend.play(machine.handle(.power(onBattery(20), now: start.addingTimeInterval(60))))
        #expect(machine.state == .off)
        // One percent above the line is not enough to come back: the charge has
        // to clear the hysteresis first.
        backend.play(machine.handle(.power(onBattery(21), now: start.addingTimeInterval(120))))
        #expect(machine.state == .off)
        backend.play(machine.handle(.power(onBattery(23), now: start.addingTimeInterval(180))))
        #expect(machine.state.isOn)
    }

    @Test("A guard the user switched off hands the assertion straight back")
    func disablingTheGuardRestores() {
        var (machine, backend) = machine(threshold: 20)
        backend.play(machine.handle(.turnOn(now: start)))
        backend.play(machine.handle(.power(onBattery(10), now: start.addingTimeInterval(60))))
        #expect(machine.state == .off)
        var options = machine.options
        options.batteryGuardEnabled = false
        backend.play(machine.handle(.optionsChanged(options, now: start.addingTimeInterval(120))))
        #expect(machine.state.isOn)
    }

    @Test("With the guard off a low battery keeps it awake")
    func guardOff() {
        var (machine, backend) = machine(guardOn: false, power: onBattery(5))
        backend.play(machine.handle(.turnOn(now: start)))
        #expect(machine.state.isOn)
        backend.play(machine.handle(.power(onBattery(3), now: start.addingTimeInterval(60))))
        #expect(machine.state.isOn)
    }

    @Test("A critical thermal state beats the guard setting and the power source")
    func thermalCritical() {
        var (machine, backend) = machine(guardOn: false)
        backend.play(machine.handle(.turnOn(now: start)))
        backend.play(
            machine.handle(
                .power(
                    PowerStatus(percent: 100, onBattery: false, thermal: .critical),
                    now: start.addingTimeInterval(60)
                )
            )
        )
        #expect(machine.state == .off)
        #expect(machine.reason == "Turned off: this Mac is too hot.")
    }

    // MARK: - Refusing on the way in

    @Test("Switching it on below the threshold is honoured until the next charge")
    func switchedOnBelowThreshold() {
        var (machine, backend) = machine(threshold: 20, power: onBattery(12))
        backend.play(machine.handle(.turnOn(now: start)))
        #expect(machine.state.isOn)
        #expect(backend.creates.count == 1)
        #expect(machine.reason == nil)

        // A further drop does not undo the user's own switch.
        backend.play(machine.handle(.power(onBattery(8), now: start.addingTimeInterval(60))))
        #expect(machine.state.isOn)

        // After a charge above the threshold the guard watches again.
        backend.play(machine.handle(.power(plugged(40), now: start.addingTimeInterval(120))))
        backend.play(machine.handle(.power(onBattery(40), now: start.addingTimeInterval(180))))
        backend.play(machine.handle(.power(onBattery(19), now: start.addingTimeInterval(240))))
        #expect(machine.state == .off)
        #expect(machine.reason == "Turned off: the battery fell to 19 %.")
    }

    @Test("Switching it on while critically hot is refused with a reason")
    func refusedWhenHot() {
        var (machine, backend) = machine(
            power: PowerStatus(percent: 100, onBattery: false, thermal: .critical)
        )
        backend.play(machine.handle(.turnOn(now: start)))
        #expect(machine.state == .off)
        #expect(backend.creates.isEmpty)
        #expect(machine.reason == "This Mac is too hot to stay awake.")
    }

    @Test("A Mac with no battery is never guarded by charge")
    func noBattery() {
        var (machine, backend) = machine(power: PowerStatus(percent: nil, onBattery: false))
        backend.play(machine.handle(.turnOn(now: start)))
        #expect(machine.state.isOn)
        backend.play(
            machine.handle(.power(PowerStatus(percent: nil, onBattery: true), now: start))
        )
        #expect(machine.state.isOn)
    }

    // MARK: - The words on screen

    @Test("The countdown never ticks in seconds")
    func countdownWording() {
        #expect(Countdown.text(remainingSeconds: 42 * 60) == "42m")
        #expect(Countdown.text(remainingSeconds: 3_900) == "1h 05m")
        #expect(Countdown.text(remainingSeconds: 30) == "under 1m")
        #expect(Countdown.text(remainingSeconds: 0) == "0m")
    }

    @Test("The threshold stepper offers the range the settings clamp to")
    func thresholdRange() {
        #expect(KeepAwakeOptions.thresholdRange == 5...50)
        #expect(KeepAwakeOptions().batteryThreshold == 20)
        #expect(KeepAwakeOptions.thresholdRange.contains(KeepAwakeOptions().batteryThreshold))
    }
}
