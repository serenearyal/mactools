import Foundation

import SMCKit

enum SMCCommands {
    static func dumpKeys() throws {
        let connection = try SMCConnection()
        let catalog = try SMCKeyCatalog.load(from: connection)
        for entry in catalog.entries {
            guard let info = entry.info else {
                print("\(entry.key)  ????  -  -  not readable")
                continue
            }
            let attributes = String(format: "0x%02x", info.attributes)
            let value = (try? connection.readBytes(entry.key, info: info))
                .map { info.type.decode($0).description } ?? "-"
            print("\(entry.key)  \(info.dataType)  \(info.dataSize)  \(attributes)  \(value)")
        }
    }

    static func sensors() throws {
        let connection = try SMCConnection()
        let catalog = try SMCKeyCatalog.load(from: connection)
        let readings = connection.readTemperatures(connection.temperatureKeys(in: catalog))
        guard !readings.isEmpty else { throw CLIError("no live temperature sensor found") }

        for category in SensorCategory.allCases {
            let group = readings.filter { $0.category == category }.sorted { $0.label < $1.label }
            guard !group.isEmpty else { continue }
            print(category.label)
            for reading in group {
                print("  \(reading.key)  \(pad(reading.label, 28))\(format(reading.celsius, digits: 1)) C")
            }
        }
    }

    static func fans() throws {
        let connection = try SMCConnection()
        let capabilities = try connection.fanCapabilities()
        print("fans: \(capabilities.fanCount)  mode key: \(capabilities.modeSuffix.map { "F%d\($0)" } ?? "none")  Ftst: \(capabilities.hasForceTargets ? "yes" : "no")")
        let readings = try connection.readFans()
        guard !readings.isEmpty else { throw CLIError("the SMC reports no fan") }
        for fan in readings {
            print("""
              fan \(fan.index): \(format(fan.actual, digits: 0)) rpm  \
            min \(format(fan.minimum, digits: 0))  max \(format(fan.maximum, digits: 0))  \
            target \(format(fan.target, digits: 0))  mode \(fan.mode.rawValue)
            """)
        }
    }

    static func power() throws {
        let connection = try SMCConnection()
        let catalog = try SMCKeyCatalog.load(from: connection)
        let readings = connection.readPower(in: catalog)
        guard !readings.isEmpty else { throw CLIError("no power sensor found") }
        for reading in readings.sorted(by: { $0.watts > $1.watts }) {
            print("  \(reading.key)  \(pad(reading.label, 28))\(format(reading.watts, digits: 2)) W")
        }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private static func format(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
