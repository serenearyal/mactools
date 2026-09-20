import Foundation

import BacklightKit

/// `ventctl backlight get|ids|auto`: read only, on purpose.
///
/// The CLI never writes the keyboard backlight. A command that dims somebody's
/// keyboard from a terminal window they cannot see is not a debugging tool, and
/// the slider in the app is one click away.
enum BacklightCommands {
    @MainActor
    static func get() throws {
        let client = KeyboardBacklightClient()
        let engine = BacklightEngine(client: client)
        guard let keyboard = engine.keyboard else { throw unavailable(engine) }
        engine.poll()
        let reading = engine.reading
        print("keyboard     \(keyboard)")
        print("built in     \(client.isBuiltIn(keyboard))")
        print("level        \(reading.level)  (\(BacklightScale.percentText(reading.level)), step \(BacklightScale.index(for: reading.level)) of \(BacklightScale.steps))")
        print("auto         \(reading.isAuto)")
        print("suppressed   \(reading.isSuppressed)")
        print("dimmed       \(reading.isDimmed)")
    }

    @MainActor
    static func ids() throws {
        let client = KeyboardBacklightClient()
        let all = client.keyboardIDs()
        guard !all.isEmpty else {
            throw CLIError(BacklightAvailability.Reason.noKeyboard.message)
        }
        print("\(MetricsCommands.pad("ID", 14))BUILT IN")
        for id in all {
            print("\(MetricsCommands.pad("\(id)", 14))\(client.isBuiltIn(id))")
        }
    }

    @MainActor
    static func auto() throws {
        let client = KeyboardBacklightClient()
        let engine = BacklightEngine(client: client)
        guard let keyboard = engine.keyboard else { throw unavailable(engine) }
        print(client.isAutoEnabled(keyboard) ? "on" : "off")
    }

    @MainActor
    private static func unavailable(_ engine: BacklightEngine) -> CLIError {
        CLIError(
            engine.availability.reason?.message
                ?? "this Mac has no keyboard backlight Vent can read"
        )
    }
}
