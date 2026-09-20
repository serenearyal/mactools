import Foundation

import HelperProtocol
import ScanKit

let usage = """
ventctl - debug CLI for Vent (protocol \(HelperConstants.protocolVersion))

usage: ventctl <command> [options]

commands:
  dump-keys    list every SMC key with its type, size, attributes and value
  sensors      print the live temperature sensors by category
  fans         print fan state and limits
  power        print the power sensors
  cpu          print total and per-core CPU usage over one second
  mem          print the memory breakdown
  disks        print the mounted volumes with their capacity
  io           print disk I/O throughput over one second
  procs        print the process table
  watch        stream CPU, memory, disk I/O, power and CPU temperature
  scan         run the largest-files scan
  helper-ping  check the privileged helper over XPC
  helper-read  read one SMC key through the privileged helper
  fan-status   print the fan state the helper sees
  fan-auto     hand one fan, or every fan, back to the firmware
  fan-set      force one fan to a constant speed
  selftest-fans  run the gentle live fan sequence with a temperature guard

options:
  procs        --sort cpu|mem   order of the table (default cpu)
               --top N          number of rows (default 15)
               --helper         merge the snapshot of the privileged helper
  watch        --interval S     seconds between lines (default 1)
  scan         --root PATH      where to start (default \(Scan.dataVolumePath))
               --top N          number of rows (default 20)
  helper-read  <KEY>            four-character SMC key, for example F0Ac
  fan-auto     [index|all]      default all
  fan-set      <index> <rpm>    clamped to the limits of that fan
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ventctl: \(message)\n".utf8))
    exit(1)
}

/// Plain `--name value` parsing, plus `--name` on its own for a flag: no
/// third-party package for five options.
struct Options {
    private var values: [String: String] = [:]
    private var present: Set<String> = []

    init(_ tokens: [String], allowed: Set<String>, flags: Set<String> = []) throws {
        var rest = tokens[...]
        while let token = rest.first {
            rest = rest.dropFirst()
            let name = String(token.dropFirst(2))
            guard token.hasPrefix("--"), allowed.contains(name) || flags.contains(name) else {
                throw CLIError("unexpected argument '\(token)'")
            }
            if flags.contains(name) {
                present.insert(name)
                continue
            }
            guard let value = rest.first else { throw CLIError("'\(token)' needs a value") }
            rest = rest.dropFirst()
            values[name] = value
        }
    }

    func string(_ name: String) -> String? { values[name] }

    func flag(_ name: String) -> Bool { present.contains(name) }

    func integer(_ name: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let text = values[name] else { return fallback }
        guard let value = Int(text), range.contains(value) else {
            throw CLIError("'--\(name)' needs a whole number between \(range.lowerBound) and \(range.upperBound)")
        }
        return value
    }

    func double(_ name: String, default fallback: Double, range: ClosedRange<Double>) throws -> Double {
        guard let text = values[name] else { return fallback }
        guard let value = Double(text), range.contains(value) else {
            throw CLIError("'--\(name)' needs a number between \(range.lowerBound) and \(range.upperBound)")
        }
        return value
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(0)
}
let tail = Array(arguments.dropFirst())

func withoutOptions() throws {
    guard tail.isEmpty else { throw CLIError("'\(command)' takes no option") }
}

do {
    switch command {
    case "dump-keys":
        try withoutOptions()
        try SMCCommands.dumpKeys()
    case "sensors":
        try withoutOptions()
        try SMCCommands.sensors()
    case "fans":
        try withoutOptions()
        try SMCCommands.fans()
    case "power":
        try withoutOptions()
        try SMCCommands.power()
    case "cpu":
        let options = try Options(tail, allowed: ["interval"])
        try MetricsCommands.cpu(interval: try options.double("interval", default: 1, range: 0.1...60))
    case "mem":
        try withoutOptions()
        try MetricsCommands.memory()
    case "disks":
        try withoutOptions()
        try MetricsCommands.disks()
    case "io":
        let options = try Options(tail, allowed: ["interval"])
        try MetricsCommands.io(interval: try options.double("interval", default: 1, range: 0.1...60))
    case "procs":
        let options = try Options(tail, allowed: ["sort", "top", "interval"], flags: ["helper"])
        let name = options.string("sort") ?? "cpu"
        guard let sort = ProcessSort(rawValue: name) else {
            throw CLIError("'--sort' takes 'cpu' or 'mem', not '\(name)'")
        }
        try MetricsCommands.processes(
            sort: sort,
            top: try options.integer("top", default: 15, range: 1...10_000),
            interval: try options.double("interval", default: 1, range: 0.1...60),
            useHelper: options.flag("helper")
        )
    case "watch":
        let options = try Options(tail, allowed: ["interval"])
        try MetricsCommands.watch(interval: try options.double("interval", default: 1, range: 0.1...60))
    case "helper-ping":
        try withoutOptions()
        try HelperCommands.ping()
    case "helper-read":
        guard tail.count == 1 else {
            throw CLIError("'helper-read' takes one SMC key, for example 'ventctl helper-read F0Ac'")
        }
        try HelperCommands.read(key: tail[0])
    case "scan":
        let options = try Options(tail, allowed: ["root", "top"])
        try ScanCommands.scan(
            root: options.string("root") ?? Scan.dataVolumePath,
            top: try options.integer("top", default: 20, range: 1...Scan.resultLimit)
        )
    case "fan-status":
        try withoutOptions()
        try FanCommands.status()
    case "fan-auto":
        guard tail.count <= 1 else {
            throw CLIError("'fan-auto' takes one fan index or 'all'")
        }
        try FanCommands.setAuto(tail.first)
    case "fan-set":
        guard tail.count == 2, let index = Int(tail[0]), let rpm = Int(tail[1]) else {
            throw CLIError("'fan-set' takes a fan index and a speed, for example 'ventctl fan-set 0 2500'")
        }
        try FanCommands.setConstant(index: index, rpm: rpm)
    case "fan-probe":
        try withoutOptions()
        try FanProbe.run()
    case "selftest-fans", "selftest":
        try withoutOptions()
        try FanCommands.selftest()
    case "-h", "--help", "help":
        print(usage)
    default:
        FileHandle.standardError.write(Data("ventctl: unknown command '\(command)'\n\n".utf8))
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(2)
    }
} catch let error as CustomStringConvertible {
    fail(error.description)
} catch {
    fail("\(error)")
}
