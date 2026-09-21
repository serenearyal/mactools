import Foundation
import Testing

/// The settings that have to survive the rename from Vent to MacTools.
///
/// The bundle identifier is the name of the defaults domain, so the rename put
/// everything the user had chosen out of reach. The copy that fixes that runs
/// on a first launch, against a domain this build did not write, and it is the
/// kind of code that gets one chance to be right: these tests drive it with two
/// dictionaries, so nothing here can touch the preferences of the Mac running
/// them.
@Suite("Settings migration")
struct SettingsMigrationTests {
    /// A defaults domain, in memory. Class, not struct: `SettingsStore` is the
    /// reference the migration writes through.
    private final class MemoryStore: SettingsStore {
        private(set) var values: [String: Any]
        /// Every key that was written, in order, so "it copied nothing" can be
        /// told apart from "it copied the same value back".
        private(set) var writes: [String] = []

        init(_ values: [String: Any] = [:]) {
            self.values = values
        }

        func object(forKey defaultName: String) -> Any? { values[defaultName] }

        func set(_ value: Any?, forKey defaultName: String) {
            writes.append(defaultName)
            values[defaultName] = value
        }
    }

    private let settingsKey = SettingsMigration.settingsKey
    private let oldFrameKey = SettingsMigration.keys[1].old
    private let newFrameKey = SettingsMigration.frameKey(SettingsMigration.mainWindowAutosaveName)

    private func blob(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - The decision

    @Test("nothing moves when the old domain has no settings")
    func noOldSettings() {
        #expect(SettingsMigration.plan(oldKeys: [], newKeys: []).isEmpty)
        // A window frame on its own is not enough: the domain was never ours.
        #expect(SettingsMigration.plan(oldKeys: [oldFrameKey], newKeys: []).isEmpty)
    }

    @Test("nothing moves when this domain already has settings")
    func alreadySettled() {
        let plan = SettingsMigration.plan(
            oldKeys: [settingsKey, oldFrameKey],
            newKeys: [settingsKey]
        )
        #expect(plan.isEmpty)
    }

    @Test("the settings and the window frame both move on a first launch")
    func firstLaunch() {
        let plan = SettingsMigration.plan(oldKeys: [settingsKey, oldFrameKey], newKeys: [])
        #expect(plan.map(\.old) == [settingsKey, oldFrameKey])
        #expect(plan.map(\.new) == [settingsKey, newFrameKey])
    }

    @Test("a key the old domain does not hold is not invented")
    func missingFrame() {
        let plan = SettingsMigration.plan(oldKeys: [settingsKey], newKeys: [])
        #expect(plan.map(\.new) == [settingsKey])
    }

    /// The frame is the one key that can already exist here while the settings
    /// do not: this build may have opened its window before the copy ran.
    @Test("a value that is already here is left alone")
    func keepsWhatIsHere() {
        let plan = SettingsMigration.plan(
            oldKeys: [settingsKey, oldFrameKey],
            newKeys: [newFrameKey]
        )
        #expect(plan.map(\.new) == [settingsKey])
    }

    // MARK: - The copy, over two stores

    @Test("the first launch copies both values across")
    func copiesAcross() {
        let old = MemoryStore([
            settingsKey: blob("{\"showDockIcon\":true}"),
            oldFrameKey: "0 0 900 600 0 0 1728 1079 ",
        ])
        let new = MemoryStore()

        let copied = SettingsMigration.run(into: new, from: old)

        #expect(copied.count == 2)
        #expect(new.object(forKey: settingsKey) as? Data == old.object(forKey: settingsKey) as? Data)
        #expect(new.object(forKey: newFrameKey) as? String == "0 0 900 600 0 0 1728 1079 ")
        // The old key name is not carried over with the value.
        #expect(new.object(forKey: oldFrameKey) == nil)
    }

    @Test("the old domain is never touched")
    func leavesTheOldDomainAlone() {
        let old = MemoryStore([settingsKey: blob("{}"), oldFrameKey: "frame"])
        SettingsMigration.run(into: MemoryStore(), from: old)

        #expect(old.writes.isEmpty)
        #expect(old.object(forKey: settingsKey) as? Data == blob("{}"))
        #expect(old.object(forKey: oldFrameKey) as? String == "frame")
    }

    @Test("running it twice writes once")
    func idempotent() {
        let old = MemoryStore([settingsKey: blob("{\"showDockIcon\":true}")])
        let new = MemoryStore()

        #expect(SettingsMigration.run(into: new, from: old).count == 1)
        #expect(new.writes == [settingsKey])

        #expect(SettingsMigration.run(into: new, from: old).isEmpty)
        #expect(new.writes == [settingsKey])
    }

    @Test("a choice made under the new name survives an old domain")
    func neverOverwrites() {
        let old = MemoryStore([settingsKey: blob("old")])
        let new = MemoryStore([settingsKey: blob("new")])

        #expect(SettingsMigration.run(into: new, from: old).isEmpty)
        #expect(new.object(forKey: settingsKey) as? Data == blob("new"))
    }

    @Test("a Mac that never ran the old name is left as it is")
    func freshInstall() {
        let new = MemoryStore()
        #expect(SettingsMigration.run(into: new, from: MemoryStore()).isEmpty)
        #expect(new.writes.isEmpty)
    }

    @Test("the domain it reads is the old bundle identifier")
    func theOldDomain() {
        #expect(SettingsMigration.legacyDomain == "com.serenearyal.vent")
        #expect(oldFrameKey == "NSWindow Frame VentMainWindow")
        #expect(newFrameKey == "NSWindow Frame MacToolsMainWindow")
    }
}
