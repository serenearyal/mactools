import Foundation
import Testing

import WindowKit

/// The window manager's own settings: the shortcut choice, the per-action
/// switches and the gap. The AX calls around them cannot be tested from a test
/// bundle, which has no Accessibility grant; these rules can.
@Suite("window settings")
struct WindowSettingsTests {
    @Test("the shortcuts are off until the user picks a set")
    func defaultsToOff() {
        let data = WindowSettingsData()
        #expect(data.shortcutChoice == .off)
        #expect(data.shortcutChoice.set == nil)
        #expect(data.gap == 0)
        #expect(data.enhancedUserInterfaceWorkaround)
        #expect(data.reactivatesAfterTile)
    }

    @Test("every action is on by default and can be switched off and back on")
    func togglesOneAction() {
        var data = WindowSettingsData()
        #expect(WindowAction.allCases.allSatisfy(data.isEnabled))
        data.setEnabled(false, for: .leftHalf)
        #expect(!data.isEnabled(.leftHalf))
        #expect(data.isEnabled(.rightHalf))
        #expect(data.disabled == [.leftHalf])
        // Twice off is still once off: the list is a set, not a log.
        data.setEnabled(false, for: .leftHalf)
        #expect(data.disabledActions == ["leftHalf"])
        data.setEnabled(true, for: .leftHalf)
        #expect(data.isEnabled(.leftHalf))
        #expect(data.disabledActions.isEmpty)
    }

    /// The list is stored as strings so an action that no longer exists cannot
    /// make the whole settings file undecodable.
    @Test("an unknown action in the stored list is ignored, not fatal")
    func survivesAnUnknownAction() {
        var data = WindowSettingsData()
        data.disabledActions = ["leftHalf", "teleport"]
        #expect(data.disabled == [.leftHalf])
        #expect(!data.isEnabled(.leftHalf))
    }

    @Test("the settings round trip through JSON")
    func roundTrips() throws {
        var data = WindowSettingsData()
        data.shortcutChoice = .alternate
        data.gap = 12
        data.enhancedUserInterfaceWorkaround = false
        data.setEnabled(false, for: .maximize)
        let encoded = try JSONEncoder().encode(data)
        #expect(try JSONDecoder().decode(WindowSettingsData.self, from: encoded) == data)
    }

    @Test("the two sets are named and the alternate one shares no chord")
    func choicesCarryTheSets() throws {
        #expect(WindowShortcutChoice.rectangle.set?.id == "rectangle")
        #expect(WindowShortcutChoice.alternate.set?.id == "alternate")
        let rectangle = try #require(WindowShortcutChoice.rectangle.set).chords
        let alternate = try #require(WindowShortcutChoice.alternate.set).chords
        #expect(rectangle.isDisjoint(with: alternate))
    }

    @Test(
        "--shortcut-set takes the three names, however they are written",
        arguments: [
            ("off", WindowShortcutChoice.off),
            ("Rectangle", .rectangle),
            ("ALTERNATE", .alternate),
        ]
    )
    func parsesTheArgument(argument: String, expected: WindowShortcutChoice) {
        #expect(WindowShortcutChoice(argument: argument) == expected)
    }

    @Test("an unknown set name is refused")
    func refusesAnUnknownArgument() {
        #expect(WindowShortcutChoice(argument: "magnet") == nil)
    }
}
