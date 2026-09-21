import Foundation
import Testing

import WindowKit

/// The one list the tab, the popover and the status menu all draw. If it
/// drifts, the three places drift with it.
@Suite("window command list")
struct WindowCommandListTests {
    @Test("every action is in exactly one group")
    func coversEveryActionOnce() {
        #expect(WindowCommandList.actions.count == WindowAction.allCases.count)
        #expect(Set(WindowCommandList.actions) == Set(WindowAction.allCases))
    }

    @Test("the groups are Rectangle's own")
    func groupOrder() {
        #expect(WindowCommandList.groupedActions.map(\.id) == [
            "halves", "corners", "thirds", "screen", "displays",
        ])
        #expect(WindowCommandList.groupedActions[0].actions == [
            .leftHalf, .rightHalf, .centerHalf, .topHalf, .bottomHalf,
        ])
        #expect(WindowCommandList.groupedActions[4].actions == [.nextDisplay, .previousDisplay])
    }

    @Test("a row carries the chord of the chosen set")
    func rowsCarryTheChord() throws {
        let groups = WindowCommandList.groups(set: .rectangle)
        let rows = groups.flatMap(\.rows)
        let left = try #require(rows.first { $0.action == .leftHalf })
        #expect(left.shortcutDisplay == "⌃⌥←")
        let centerHalf = try #require(rows.first { $0.action == .centerHalf })
        #expect(centerHalf.shortcutDisplay == nil)
    }

    @Test("no set means no chord on any row")
    func noSetNoChords() {
        let rows = WindowCommandList.groups(set: nil).flatMap(\.rows)
        #expect(rows.allSatisfy { $0.shortcutDisplay == nil })
        #expect(rows.count == WindowAction.allCases.count)
    }

    @Test("a switched-off action keeps its row and loses its chord")
    func disabledActionHasNoChord() throws {
        let rows = WindowCommandList.groups(set: .rectangle, disabled: [.maximize]).flatMap(\.rows)
        let maximize = try #require(rows.first { $0.action == .maximize })
        #expect(maximize.shortcutDisplay == nil)
        #expect(rows.first { $0.action == .leftHalf }?.shortcutDisplay == "⌃⌥←")
    }

    @Test("the display moves are unavailable on a Mac with one screen")
    func displayMovesNeedASecondScreen() {
        let one = WindowCommandList.groups(set: .rectangle, canAct: true, screenCount: 1)
            .flatMap(\.rows)
        #expect(one.first { $0.action == .nextDisplay }?.isAvailable == false)
        #expect(one.first { $0.action == .leftHalf }?.isAvailable == true)

        let two = WindowCommandList.groups(set: .rectangle, canAct: true, screenCount: 2)
            .flatMap(\.rows)
        #expect(two.first { $0.action == .nextDisplay }?.isAvailable == true)
    }

    @Test("with no window to move, nothing is available")
    func noWindowNothingAvailable() {
        let rows = WindowCommandList.groups(set: .rectangle, canAct: false, screenCount: 2)
            .flatMap(\.rows)
        #expect(rows.allSatisfy { !$0.isAvailable })
    }
}
