import Foundation
import Testing

import WindowKit

/// Rectangle ships Center Half and Almost Maximize without a chord, and Vent
/// ships what Rectangle ships. Every other action has exactly one.
@Test("a set binds every action but the two Rectangle leaves open", arguments: ShortcutSet.all)
func everyActionHasOneBinding(set: ShortcutSet) {
    #expect(set.bindings.count == WindowAction.allCases.count - ShortcutSet.unbound.count)
    for action in WindowAction.allCases where !ShortcutSet.unbound.contains(action) {
        #expect(set.binding(for: action) != nil, "\(set.id) has no binding for \(action.rawValue)")
    }
    for action in ShortcutSet.unbound {
        #expect(set.binding(for: action) == nil, "\(set.id) binds \(action.rawValue)")
    }
}

@Test("the actions without a default are Center Half and Almost Maximize")
func unboundActions() {
    #expect(ShortcutSet.unbound == [.centerHalf, .almostMaximize])
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

@Test("the alternate set keeps the key of every action")
func alternateKeepsTheKeys() throws {
    for action in WindowAction.allCases where !ShortcutSet.unbound.contains(action) {
        let first = try #require(ShortcutSet.rectangle.binding(for: action))
        let second = try #require(ShortcutSet.alternate.binding(for: action))
        #expect(first.keyCode == second.keyCode)
        #expect(first.modifiers.contains(.option))
        // Every chord of the first set carries ⌥, so a chord without it can
        // never collide with one: that is what the three extras rely on.
        #expect(second.modifiers != first.modifiers)
    }
}

/// Rectangle's defaults, read off its own menu. A wrong line here is a
/// shortcut that does nothing in the fingers of somebody who used Rectangle.
@Test(
    "the shortcuts are the ones Rectangle ships",
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
        (.maximizeHeight, "⌃⌥⇧↑"),
        (.previousDisplay, "⌃⌥⌘←"),
        (.nextDisplay, "⌃⌥⌘→"),
    ]
)
func rectangleSetDisplay(action: WindowAction, display: String) throws {
    let binding = try #require(ShortcutSet.rectangle.binding(for: action))
    #expect(binding.display == display)
}

@Test(
    "the alternate set moves every chord out of the first one's way",
    arguments: [
        (WindowAction.leftHalf, "⌃⌥⇧⌘←"),
        (.maximize, "⌃⌥⇧⌘↩"),
        (.topLeft, "⌃⌥⇧⌘U"),
        (.nextDisplay, "⌃⇧⌘→"),
        (.previousDisplay, "⌃⇧⌘←"),
        (.maximizeHeight, "⌃⇧⌘↑"),
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

@Test("there are eighteen placements and five other actions")
func placementCount() {
    #expect(WindowAction.placements.count == 18)
    #expect(WindowAction.allCases.count == 23)
}

@Test("only the two display moves need a second screen", arguments: WindowAction.allCases)
func needsSecondDisplay(action: WindowAction) {
    let moves: Set<WindowAction> = [.nextDisplay, .previousDisplay]
    #expect(action.needsSecondDisplay == moves.contains(action))
}

@Test("every refusal has a sentence for the user", arguments: WindowRefusal.allCases)
func refusalsHaveMessages(refusal: WindowRefusal) {
    #expect(refusal.message.isEmpty == false)
    #expect(refusal.message.hasSuffix("."))
}
