import Foundation

/// "Stay awake with the lid closed", as rules and as words.
///
/// An `IOPMAssertion` of any type stops idle sleep and nothing else: close the
/// lid, or pick Sleep in the Apple menu, and the Mac sleeps anyway. The only
/// thing that changes that is the system-wide `SleepDisabled` setting, which
/// is what `sudo pmset disablesleep 1` writes and what MacTools' privileged
/// helper can write for the user.
///
/// It is the more dangerous of the two by a long way - a Mac that cannot sleep
/// with its lid shut is a Mac that cooks in a bag - so the rules for giving it
/// back live here, pure and tested, and the effects live in the controller.
public enum LidSleepPolicy {
    /// At this thermal state and above, the flag comes off whatever the user
    /// asked for. The same idea as the battery guard's critical rule, one
    /// notch earlier: idle sleep being blocked on a hot desk Mac is a nuisance,
    /// a closed hot Mac in a bag is the real danger.
    public static let thermalCeiling = ProcessInfo.ThermalState.serious

    /// The one-line caption the UI shows under the switch.
    public static let thermalCaption =
        "A closed Mac that cannot sleep gets hot in a bag, so MacTools lets it sleep again "
            + "when this Mac reaches a serious thermal state."

    /// Whether MacTools should be holding the flag at this instant.
    ///
    /// Keep Awake itself has to be on: the lid option is a stronger form of
    /// Keep Awake, never a second switch that works on its own. Everything
    /// that turns Keep Awake off - the switch, the timer, the battery guard -
    /// therefore takes the flag with it, without a rule of its own.
    public static func wantsHold(
        keepAwakeOn: Bool,
        lidOptionOn: Bool,
        thermal: ProcessInfo.ThermalState = .nominal
    ) -> Bool {
        guard keepAwakeOn, lidOptionOn else { return false }
        return thermal.rawValue < thermalCeiling.rawValue
    }
}

/// What this Mac is actually refusing to do right now, read back from the
/// system rather than assumed from a switch.
///
/// Every field comes from a read: the assertions from
/// `IOPMCopyAssertionsByProcess` for this process, the flag from the helper or
/// from `IOPMCopySystemPowerSettings`. A toggle that says "on" while the
/// kernel holds nothing is the bug this type exists to make impossible.
public struct AwakeBlocking: Sendable, Equatable {
    /// MacTools holds `PreventUserIdleSystemSleep`.
    public var idleSleepHeld: Bool
    /// MacTools holds `PreventUserIdleDisplaySleep` too.
    public var displaySleepHeld: Bool
    /// `SleepDisabled` is set, by anybody.
    public var lidSleepBlocked: Bool
    /// And it was MacTools that set it.
    public var lidSleepIsOurs: Bool

    public init(
        idleSleepHeld: Bool = false,
        displaySleepHeld: Bool = false,
        lidSleepBlocked: Bool = false,
        lidSleepIsOurs: Bool = false
    ) {
        self.idleSleepHeld = idleSleepHeld
        self.displaySleepHeld = displaySleepHeld
        self.lidSleepBlocked = lidSleepBlocked
        self.lidSleepIsOurs = lidSleepIsOurs
    }

    /// The tab's status line and the popover row's second line. Plain words
    /// about what is blocked, never about what was clicked.
    public var title: String {
        switch (idleSleepHeld, lidSleepBlocked) {
        case (true, true):
            "Idle sleep and lid-close sleep blocked"
        case (true, false):
            "Idle sleep blocked"
        case (false, true):
            lidSleepIsOurs
                ? "Lid-close sleep blocked"
                : "This Mac cannot sleep at all - set with pmset, not by MacTools"
        case (false, false):
            "This Mac sleeps as usual"
        }
    }

    /// The status light in the menu bar and next to the Keep Awake switch.
    public var led: AwakeLED {
        if lidSleepBlocked { return .red }
        return idleSleepHeld ? .amber : .green
    }

    /// True while anything at all is held, MacTools' or not.
    public var isBlockingAnything: Bool { idleSleepHeld || lidSleepBlocked }

    /// One line of the "What it does" list: what is stopped, and what is not.
    public struct Line: Sendable, Equatable, Identifiable {
        /// True for a thing this mode does stop, false for one it does not.
        public let stops: Bool
        public let text: String
        public var id: String { text }
    }

    /// The truthful version of the "What it does" list, which changes with the
    /// mode: the lid line is a promise in one mode and a warning in the other,
    /// so it is derived here instead of written twice in the UI.
    public static func summary(lidHeld: Bool, displayHeld: Bool) -> [Line] {
        [
            Line(stops: true, text: "Stops the idle sleep that follows a spell of no input."),
            lidHeld
                ? Line(
                    stops: true,
                    text: "Stops a closed lid, and the Apple menu's Sleep, from sleeping this Mac."
                )
                : Line(
                    stops: false,
                    text: "Does not stop a sleep you ask for: the Apple menu, the power button "
                        + "and a closed lid all still sleep this Mac."
                ),
            displayHeld
                ? Line(stops: true, text: "Keeps the display lit as well.")
                : Line(
                    stops: false,
                    text: "Does not stop the display dimming unless \"Keep the display on\" is on."
                ),
        ]
    }
}

/// One light, three states, read back from the power manager like the words
/// beside it: what is blocked, never what was clicked.
public enum AwakeLED: String, Sendable, Equatable, CaseIterable {
    /// This Mac sleeps as usual.
    case green
    /// Idle sleep is blocked; a closed lid still sleeps it.
    case amber
    /// Lid-close sleep is blocked: this Mac stays awake in a bag.
    case red

    /// The legend, short enough for one line under the switch.
    public var meaning: String {
        switch self {
        case .green: "sleeps as usual"
        case .amber: "idle sleep blocked"
        case .red: "lid-close sleep blocked"
        }
    }
}
