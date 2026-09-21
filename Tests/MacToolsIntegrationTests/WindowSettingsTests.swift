import Foundation
import Testing

import WindowKit

/// The window manager's own settings: the shortcut choice, the per-action
/// switches and the gap. The AX calls around them cannot be tested from a test
/// bundle, which has no Accessibility grant; these rules can.
@Suite("window settings")
struct WindowSettingsTests {
    /// A feature that is off by default is a feature that does not work: the
    /// shortcuts are Rectangle's out of the box.
    @Test("the shortcuts are Rectangle's by default")
    func defaultsToRectangle() {
        let data = WindowSettingsData()
        #expect(data.shortcutChoice == .rectangle)
        #expect(data.shortcutChoice.set?.id == "rectangle")
        #expect(data.shortcutChoiceIsUserChoice == false)
        #expect(data.gap == 0)
        #expect(data.enhancedUserInterfaceWorkaround)
        #expect(data.reactivatesAfterTile)
    }

    /// The settings file of every build before this one says "off", because
    /// that was the default and nobody chose it.
    @Test("an off nobody chose becomes Rectangle's layout")
    func migratesTheOldDefault() throws {
        let stored = #"{"shortcutChoice":"off","disabledActions":[],"gap":12}"#
        let data = try JSONDecoder().decode(WindowSettingsData.self, from: Data(stored.utf8))
        #expect(data.shortcutChoice == .rectangle)
        // Nothing else of the file is touched.
        #expect(data.gap == 12)
    }

    @Test("an off the user chose is kept")
    func keepsADeliberateOff() throws {
        let stored = #"{"shortcutChoice":"off","shortcutChoiceIsUserChoice":true}"#
        let data = try JSONDecoder().decode(WindowSettingsData.self, from: Data(stored.utf8))
        #expect(data.shortcutChoice == .off)
        #expect(data.shortcutChoice.set == nil)
    }

    @Test(
        "a set the user chose is never migrated",
        arguments: [WindowShortcutChoice.rectangle, .alternate]
    )
    func keepsAChosenSet(choice: WindowShortcutChoice) throws {
        var data = WindowSettingsData()
        data.shortcutChoice = choice
        data.shortcutChoiceIsUserChoice = true
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(WindowSettingsData.self, from: encoded)
        #expect(decoded.shortcutChoice == choice)
        #expect(decoded.shortcutChoiceIsUserChoice)
    }

    @Test("the migration is idempotent and only ever touches off")
    func migrationIsPure() {
        var data = WindowSettingsData()
        data.shortcutChoice = .off
        data.migrateShortcutChoice()
        #expect(data.shortcutChoice == .rectangle)
        data.migrateShortcutChoice()
        #expect(data.shortcutChoice == .rectangle)
        #expect(data.shortcutChoiceIsUserChoice == false)
    }

    /// A file written by a build that did not know this key at all.
    @Test("a settings file with no window key at all gets the defaults")
    func emptyObjectDecodes() throws {
        let data = try JSONDecoder().decode(WindowSettingsData.self, from: Data("{}".utf8))
        #expect(data == WindowSettingsData())
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
