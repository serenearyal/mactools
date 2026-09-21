import Foundation
import Testing

import AwakeKit

// MARK: - Durations

@Test("the presets are the five the menu offers")
func durationPresets() {
    #expect(KeepAwakeDuration.presets == [.indefinite, .minutes(30), .minutes(60), .minutes(120), .minutes(240)])
}

@Test(
    "a duration is a number of seconds, or none at all",
    arguments: [
        (KeepAwakeDuration.indefinite, nil as Int?),
        (.minutes(30), 1800),
        (.minutes(60), 3600),
        (.minutes(120), 7200),
        (.minutes(240), 14400),
        (.minutes(0), 0),
        (.minutes(-5), 0),
    ]
)
func durationSeconds(duration: KeepAwakeDuration, seconds: Int?) {
    #expect(duration.seconds == seconds)
}

@Test(
    "a duration says its name",
    arguments: [
        (KeepAwakeDuration.indefinite, "Indefinitely"),
        (.minutes(1), "1 minute"),
        (.minutes(30), "30 minutes"),
        (.minutes(60), "1 hour"),
        (.minutes(90), "90 minutes"),
        (.minutes(120), "2 hours"),
        (.minutes(240), "4 hours"),
    ]
)
func durationTitle(duration: KeepAwakeDuration, title: String) {
    #expect(duration.title == title)
}

@Test("a duration survives being stored and read back", arguments: KeepAwakeDuration.presets)
func durationIsCodable(duration: KeepAwakeDuration) throws {
    let data = try JSONEncoder().encode(duration)
    #expect(try JSONDecoder().decode(KeepAwakeDuration.self, from: data) == duration)
}

@Test(
    "the countdown reads like a clock, not like a stopwatch",
    arguments: [
        (0, "0m"),
        (-10, "0m"),
        (1, "under 1m"),
        (59, "under 1m"),
        (60, "1m"),
        (2520, "42m"),
        (2579, "42m"),
        (3600, "1h 00m"),
        (3900, "1h 05m"),
        (7199, "1h 59m"),
        (14400, "4h 00m"),
    ]
)
func countdownText(seconds: Int, text: String) {
    #expect(Countdown.text(remainingSeconds: seconds) == text)
}

// MARK: - The assertion

@Test("an indefinite request has no timeout")
func assertionWithoutTimeout() {
    let request = AssertionRequest.make(duration: .indefinite, keepDisplayOn: false)
    #expect(request.systemSleep)
    #expect(request.displaySleep == false)
    #expect(request.timeoutSeconds == nil)
    #expect(request.name == "Vent Keep Awake")
    #expect(request.details == "Vent keeps this Mac awake until you turn it off.")
}

@Test("a timed request carries the timeout the kernel needs")
func assertionWithTimeout() {
    let request = AssertionRequest.make(duration: .minutes(120), keepDisplayOn: true)
    #expect(request.timeoutSeconds == 7200)
    #expect(request.displaySleep)
    #expect(request.details == "Vent keeps this Mac and its display awake for 2 hours.")
}

@Test("the app name goes into what the user reads")
func assertionName() {
    let request = AssertionRequest.make(duration: .minutes(30), keepDisplayOn: false, appName: "ventctl")
    #expect(request.name == "ventctl Keep Awake")
    #expect(request.details == "ventctl keeps this Mac awake for 30 minutes.")
}

// MARK: - The lid hold

@Test("the lid hold needs Keep Awake and the option, both")
func lidNeedsBoth() {
    #expect(LidSleepPolicy.wantsHold(keepAwakeOn: true, lidOptionOn: true))
    #expect(!LidSleepPolicy.wantsHold(keepAwakeOn: true, lidOptionOn: false))
    #expect(!LidSleepPolicy.wantsHold(keepAwakeOn: false, lidOptionOn: true))
    #expect(!LidSleepPolicy.wantsHold(keepAwakeOn: false, lidOptionOn: false))
}

/// A closed Mac that cannot sleep is the dangerous one, so the flag comes off
/// a notch earlier than the assertion does.
@Test(
    "a hot Mac gets its lid sleep back at serious, not at critical",
    arguments: [
        (ProcessInfo.ThermalState.nominal, true),
        (.fair, true),
        (.serious, false),
        (.critical, false),
    ]
)
func lidThermalCeiling(state: ProcessInfo.ThermalState, held: Bool) {
    #expect(LidSleepPolicy.wantsHold(keepAwakeOn: true, lidOptionOn: true, thermal: state) == held)
}

@Test("the thermal ceiling is the one the caption promises")
func lidThermalCaption() {
    #expect(LidSleepPolicy.thermalCeiling == .serious)
    #expect(LidSleepPolicy.thermalCaption.contains("serious"))
}

// MARK: - What is blocked, in words

@Test(
    "the status line says what is blocked, never what was clicked",
    arguments: [
        (false, false, false, "This Mac sleeps as usual"),
        (true, false, false, "Idle sleep blocked"),
        (true, true, true, "Idle sleep and lid-close sleep blocked"),
        (false, true, true, "Lid-close sleep blocked"),
        (false, true, false, "This Mac cannot sleep at all - set with pmset, not by Vent"),
    ]
)
func blockingTitle(idle: Bool, lid: Bool, ours: Bool, title: String) {
    let blocking = AwakeBlocking(idleSleepHeld: idle, lidSleepBlocked: lid, lidSleepIsOurs: ours)
    #expect(blocking.title == title)
    #expect(blocking.isBlockingAnything == (idle || lid))
}

@Test("the \"what it does\" list tells the truth in both modes")
func blockingSummary() {
    let withoutLid = AwakeBlocking.summary(lidHeld: false, displayHeld: false)
    #expect(withoutLid.count == 3)
    #expect(withoutLid[0].stops)
    #expect(!withoutLid[1].stops)
    #expect(withoutLid[1].text.contains("closed lid all still sleep this Mac"))
    #expect(!withoutLid[2].stops)

    let withLid = AwakeBlocking.summary(lidHeld: true, displayHeld: true)
    #expect(withLid.filter(\.stops).count == withLid.count)
    #expect(withLid[1].text.contains("Stops a closed lid"))
    #expect(withLid[2].text.contains("display"))
}

// MARK: - The battery guard

@Test("on power nothing is released")
func guardOnPower() {
    #expect(
        BatteryGuard.decide(
            onBattery: false,
            percent: 5,
            threshold: 20,
            isOn: true,
            wasReleasedByGuard: false
        ) == .keep
    )
}

@Test("a low battery releases the assertion")
func guardReleasesOnALowBattery() {
    #expect(
        BatteryGuard.decide(
            onBattery: true,
            percent: 20,
            threshold: 20,
            isOn: true,
            wasReleasedByGuard: false
        ) == .release
    )
    #expect(
        BatteryGuard.decide(
            onBattery: true,
            percent: 21,
            threshold: 20,
            isOn: true,
            wasReleasedByGuard: false
        ) == .keep
    )
}

/// Three points of hysteresis: a battery sitting on the line must not switch
/// the assertion on and off every notification.
@Test(
    "the charge has to climb three points before the guard gives it back",
    arguments: [
        (20, BatteryGuard.Decision.keep),
        (21, .keep),
        (22, .keep),
        (23, .mayRestore),
        (30, .mayRestore),
    ]
)
func guardHysteresis(percent: Int, decision: BatteryGuard.Decision) {
    #expect(
        BatteryGuard.decide(
            onBattery: true,
            percent: percent,
            threshold: 20,
            isOn: false,
            wasReleasedByGuard: true
        ) == decision
    )
}

/// The user's own "off" is not the guard's to undo.
@Test("an assertion the user turned off is not restored")
func guardDoesNotUndoTheUser() {
    #expect(
        BatteryGuard.decide(
            onBattery: true,
            percent: 90,
            threshold: 20,
            isOn: false,
            wasReleasedByGuard: false
        ) == .keep
    )
    #expect(
        BatteryGuard.decide(
            onBattery: false,
            percent: 90,
            threshold: 20,
            isOn: false,
            wasReleasedByGuard: false
        ) == .keep
    )
}

@Test("plugging the Mac in gives back what the guard took")
func guardRestoresOnPower() {
    #expect(
        BatteryGuard.decide(
            onBattery: false,
            percent: 5,
            threshold: 20,
            isOn: false,
            wasReleasedByGuard: true
        ) == .mayRestore
    )
}

@Test("a critical thermal state releases whatever the power is")
func guardReleasesWhenCritical() {
    for onBattery in [true, false] {
        #expect(
            BatteryGuard.decide(
                onBattery: onBattery,
                percent: 100,
                threshold: 20,
                isOn: true,
                wasReleasedByGuard: false,
                thermal: .critical
            ) == .release
        )
        // And nothing is restored while it lasts.
        #expect(
            BatteryGuard.decide(
                onBattery: onBattery,
                percent: 100,
                threshold: 20,
                isOn: false,
                wasReleasedByGuard: true,
                thermal: .critical
            ) == .keep
        )
    }
}

@Test(
    "a warm Mac is not a hot one",
    arguments: [ProcessInfo.ThermalState.nominal, .fair, .serious]
)
func guardIgnoresTheLesserThermalStates(state: ProcessInfo.ThermalState) {
    #expect(
        BatteryGuard.decide(
            onBattery: false,
            percent: 100,
            threshold: 20,
            isOn: true,
            wasReleasedByGuard: false,
            thermal: state
        ) == .keep
    )
}

@Test("a threshold of zero turns the guard off")
func guardCanBeTurnedOff() {
    #expect(
        BatteryGuard.decide(
            onBattery: true,
            percent: 1,
            threshold: 0,
            isOn: true,
            wasReleasedByGuard: false
        ) == .keep
    )
}

@Suite("Awake LED")
struct AwakeLEDTests {
    @Test("green when nothing is held, amber for idle sleep, red whenever the lid flag is set")
    func states() {
        #expect(AwakeBlocking().led == .green)
        #expect(AwakeBlocking(idleSleepHeld: true).led == .amber)
        #expect(AwakeBlocking(idleSleepHeld: true, lidSleepBlocked: true, lidSleepIsOurs: true).led == .red)
        // A flag somebody set with pmset is just as red: the Mac stays awake
        // in a bag whoever asked for it.
        #expect(AwakeBlocking(lidSleepBlocked: true).led == .red)
    }
}
