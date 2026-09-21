import Foundation

/// A place the user's choices are kept: `UserDefaults` in the app, a dictionary
/// in the tests.
///
/// Two methods, because that is all the migration needs. The protocol exists so
/// the rules below can be proved against two stores that are nowhere near the
/// preferences of the Mac running the test.
protocol SettingsStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: SettingsStore {}

/// One preference that crosses the rename.
struct SettingsMigrationKey: Equatable, Sendable {
    /// Its name in the old defaults domain.
    let old: String
    /// Its name in this app's domain. The settings blob keeps its name; a
    /// window frame does not, because AppKit spells the autosave name into the
    /// key it writes.
    let new: String
}

/// The user's settings, carried across the rename from Vent to MacTools.
///
/// The bundle identifier changed with the name, and a bundle identifier is the
/// name of the defaults domain: everything the user had chosen is still on disk
/// under `com.serenearyal.vent` and invisible to this build. This copies it
/// over once, on the first launch that finds nothing of its own.
///
/// Three rules, and the reason for each:
/// 1. It runs only when this domain has no settings of its own. That makes it
///    idempotent - after the copy there are settings here, so the next launch
///    does nothing - and it means a user who has already chosen something under
///    the new name never has it overwritten by a stale old file.
/// 2. It never deletes or rewrites the old domain. If this build turns out to
///    be wrong about something, the user's original choices are untouched, and
///    a preferences file of a few kilobytes is not worth the risk of removing.
/// 3. It copies raw values, not decoded settings. `SettingsData` already
///    decodes every key optionally, so a blob written by an older build keeps
///    what it holds and falls back for the rest; putting a decode in the
///    middle of the copy would add a way to lose the lot.
enum SettingsMigration {
    /// The defaults domain of the product before the 2026-09-21 rename. Frozen:
    /// it names a file this build did not write.
    static let legacyDomain = "com.serenearyal.vent"

    /// The one key `AppSettings` stores everything in.
    static let settingsKey = "settings.v1"

    /// The autosave name of the main window, which AppKit turns into a
    /// preference key of its own.
    static let mainWindowAutosaveName = "MacToolsMainWindow"
    private static let legacyMainWindowAutosaveName = "VentMainWindow"

    /// The key AppKit writes for a window with this autosave name.
    static func frameKey(_ autosaveName: String) -> String { "NSWindow Frame \(autosaveName)" }

    /// Everything that follows the user across, in the order it is copied.
    static let keys = [
        SettingsMigrationKey(old: settingsKey, new: settingsKey),
        SettingsMigrationKey(
            old: frameKey(legacyMainWindowAutosaveName),
            new: frameKey(mainWindowAutosaveName)
        ),
    ]

    /// The decision, over facts alone: which keys to copy, given what each
    /// domain holds.
    ///
    /// Nothing at all unless the old domain has settings and this one has none.
    /// "The old domain has a window frame but no settings" is a domain this app
    /// never wrote, and the frame alone is not worth acting on.
    static func plan(oldKeys: Set<String>, newKeys: Set<String>) -> [SettingsMigrationKey] {
        guard oldKeys.contains(settingsKey), !newKeys.contains(settingsKey) else { return [] }
        return keys.filter { oldKeys.contains($0.old) && !newKeys.contains($0.new) }
    }

    /// Reads both stores, decides, and copies. Returns what it copied, which is
    /// empty on every launch after the first.
    @discardableResult
    static func run(into destination: any SettingsStore, from source: any SettingsStore)
        -> [SettingsMigrationKey]
    {
        let oldKeys = Set(keys.map(\.old).filter { source.object(forKey: $0) != nil })
        let newKeys = Set(keys.map(\.new).filter { destination.object(forKey: $0) != nil })
        let copies = plan(oldKeys: oldKeys, newKeys: newKeys)
        for key in copies {
            destination.set(source.object(forKey: key.old), forKey: key.new)
        }
        return copies
    }

    /// The app's own call, at the moment `AppSettings` is built and before it
    /// reads anything.
    ///
    /// `UserDefaults(suiteName:)` answers nil for a name this process may not
    /// have, and the old domain is simply absent on a Mac that never ran the
    /// old name; both are the ordinary case and neither is worth a word.
    static func runIfNeeded(into destination: UserDefaults) {
        guard let source = UserDefaults(suiteName: legacyDomain) else { return }
        let copied = run(into: destination, from: source)
        guard !copied.isEmpty else { return }
        AppLog.app.notice(
            """
            settings migrated from \(legacyDomain, privacy: .public): \
            \(copied.map(\.new).joined(separator: ", "), privacy: .public)
            """
        )
    }
}
