import Foundation
import Testing

import WindowKit

@Test("a set binds every action exactly once", arguments: ShortcutSet.all)
func everyActionHasOneBinding(set: ShortcutSet) {
    #expect(set.bindings.count == WindowAction.allCases.count)
    for action in WindowAction.allCases {
        #expect(set.binding(for: action) != nil, "\(set.id) has no binding for \(action.rawValue)")
    }
}

@Test("a set has no chord twice", arguments: ShortcutSet.all)
func noDuplicateChordsInASet(set: ShortcutSet) {
    #expect(set.chords.count == set.bindings.count)
}

/// The whole point of the second set: on a Mac where another app holds the
/// first one, not one chord may be shared.
@Test("the two sets share nothing")
func theSetsDoNotOverlap() {
    #expect(ShortcutSet.rectangle.chords.isDisjoint(with: ShortcutSet.alternate.chords))
}

@Test("the alternate set is the first one with shift added")
func alternateIsTheShiftedSet() throws {
    for action in WindowAction.allCases {
        let first = try #require(ShortcutSet.rectangle.binding(for: action))
        let second = try #require(ShortcutSet.alternate.binding(for: action))
        #expect(first.keyCode == second.keyCode)
        #expect(second.modifiers == first.modifiers.union(.shift))
        #expect(first.modifiers.contains(.shift) == false)
    }
}

@Test(
    "the tile shortcuts are the ones Rectangle uses",
    arguments: [
        (WindowAction.leftHalf, "⌃⌥←"),
        (.rightHalf, "⌃⌥→"),
        (.topHalf, "⌃⌥↑"),
        (.bottomHalf, "⌃⌥↓"),
        (.topLeft, "⌃⌥U"),
        (.topRight, "⌃⌥I"),
        (.bottomLeft, "⌃⌥J"),
        (.bottomRight, "⌃⌥K"),
        (.maximize, "⌃⌥↩"),
        (.center, "⌃⌥C"),
        (.firstThird, "⌃⌥D"),
        (.centerThird, "⌃⌥F"),
        (.lastThird, "⌃⌥G"),
        (.firstTwoThirds, "⌃⌥E"),
        (.lastTwoThirds, "⌃⌥T"),
        (.restore, "⌃⌥⌫"),
        (.smaller, "⌃⌥-"),
        (.larger, "⌃⌥="),
        (.previousDisplay, "⌃⌥⌘←"),
        (.nextDisplay, "⌃⌥⌘→"),
        (.maximizeHeight, "⌃⌥⌘↑"),
        (.almostMaximize, "⌃⌥⌘↩"),
    ]
)
func rectangleSetDisplay(action: WindowAction, display: String) throws {
    let binding = try #require(ShortcutSet.rectangle.binding(for: action))
    #expect(binding.display == display)
}

@Test(
    "the alternate set adds the shift symbol in the right place",
    arguments: [
        (WindowAction.leftHalf, "⌃⌥⇧←"),
        (.maximize, "⌃⌥⇧↩"),
        (.topLeft, "⌃⌥⇧U"),
        (.nextDisplay, "⌃⌥⇧⌘→"),
        (.maximizeHeight, "⌃⌥⇧⌘↑"),
        (.almostMaximize, "⌃⌥⇧⌘↩"),
    ]
)
func alternateSetDisplay(action: WindowAction, display: String) throws {
    let binding = try #require(ShortcutSet.alternate.binding(for: action))
    #expect(binding.display == display)
}

@Test("the modifier symbols come in the order macOS writes them")
func modifierOrder() {
    #expect(HotKeyModifiers([.command, .shift, .option, .control]).display == "⌃⌥⇧⌘")
    #expect(HotKeyModifiers([]).display == "")
    #expect(HotKeyModifiers.shift.display == "⇧")
}

/// The numbers Carbon expects. They are written down here because a wrong one
/// registers a shortcut nobody can press.
@Test(
    "the modifiers convert to the Carbon masks",
    arguments: [
        (HotKeyModifiers.control, UInt32(0x1000)),
        (HotKeyModifiers.option, UInt32(0x0800)),
        (HotKeyModifiers.shift, UInt32(0x0200)),
        (HotKeyModifiers.command, UInt32(0x0100)),
        (HotKeyModifiers([.control, .option]), UInt32(0x1800)),
        (HotKeyModifiers([.control, .option, .shift, .command]), UInt32(0x1B00)),
    ]
)
func carbonFlags(modifiers: HotKeyModifiers, flags: UInt32) {
    #expect(modifiers.carbonFlags == flags)
}

@Test("the key codes are the ANSI ones")
func keyCodeValues() {
    #expect(KeyCode.u == 32)
    #expect(KeyCode.i == 34)
    #expect(KeyCode.j == 38)
    #expect(KeyCode.k == 40)
    #expect(KeyCode.c == 8)
    #expect(KeyCode.d == 2)
    #expect(KeyCode.f == 3)
    #expect(KeyCode.g == 5)
    #expect(KeyCode.e == 14)
    #expect(KeyCode.t == 17)
    #expect(KeyCode.returnKey == 36)
    #expect(KeyCode.delete == 51)
    #expect(KeyCode.minus == 27)
    #expect(KeyCode.equal == 24)
    #expect(KeyCode.left == 123)
    #expect(KeyCode.right == 124)
    #expect(KeyCode.down == 125)
    #expect(KeyCode.up == 126)
}

@Test("an unknown key still prints something")
func unknownKeyDisplay() {
    #expect(KeyCode.display(999) == "Key 999")
}

@Test("a binding survives being stored and read back")
func bindingIsCodable() throws {
    let binding = HotKeyBinding(action: .leftHalf, keyCode: KeyCode.left, modifiers: [.control, .option])
    let data = try JSONEncoder().encode(binding)
    #expect(try JSONDecoder().decode(HotKeyBinding.self, from: data) == binding)
}

@Test("the action ids are the stored strings")
func actionRawValues() {
    #expect(WindowAction.leftHalf.rawValue == "leftHalf")
    #expect(WindowAction.almostMaximize.rawValue == "almostMaximize")
    #expect(WindowAction(rawValue: "previousDisplay") == .previousDisplay)
    #expect(WindowAction(rawValue: "left-half") == nil)
}

@Test("every action has a title and an icon", arguments: WindowAction.allCases)
func actionsHaveLabels(action: WindowAction) {
    #expect(action.title.isEmpty == false)
    #expect(action.symbolName.isEmpty == false)
    // No em or en dash anywhere in the app, not even in a button title.
    #expect(action.title.contains("\u{2014}") == false)
    #expect(action.title.contains("\u{2013}") == false)
}

@Test("there are seventeen placements and five other actions")
func placementCount() {
    #expect(WindowAction.placements.count == 17)
    #expect(WindowAction.allCases.count == 22)
}

@Test("every refusal has a sentence for the user", arguments: WindowRefusal.allCases)
func refusalsHaveMessages(refusal: WindowRefusal) {
    #expect(refusal.message.isEmpty == false)
    #expect(refusal.message.hasSuffix("."))
}
