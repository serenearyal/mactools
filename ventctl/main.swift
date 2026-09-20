import Foundation

import HelperProtocol

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
  selftest     run the fan safety sequence

options:
  procs        --sort cpu|mem   order of the table (default cpu)
               --top N          number of rows (default 15)
  watch        --interval S     seconds between lines (default 1)
  helper-read  <KEY>            four-character SMC key, for example F0Ac
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ventctl: \(message)\n".utf8))
    exit(1)
}

/// Plain `--name value` parsing: no third-party package for four options.
struct Options {
    private var values: [String: String] = [:]

    init(_ tokens: [String], allowed: Set<String>) throws {
        var rest = tokens[...]
        while let token = rest.first {
            rest = rest.dropFirst()
            guard token.hasPrefix("--"), allowed.contains(String(token.dropFirst(2))) else {
                throw CLIError("unexpected argument '\(token)'")
            }
            guard let value = rest.first else { throw CLIError("'\(token)' needs a value") }
            rest = rest.dropFirst()
            values[String(token.dropFirst(2))] = value
        }
    }

    func string(_ name: String) -> String? { values[name] }

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
        let options = try Options(tail, allowed: ["sort", "top", "interval"])
        let name = options.string("sort") ?? "cpu"
        guard let sort = ProcessSort(rawValue: name) else {
            throw CLIError("'--sort' takes 'cpu' or 'mem', not '\(name)'")
        }
        try MetricsCommands.processes(
            sort: sort,
            top: try options.integer("top", default: 15, range: 1...10_000),
            interval: try options.double("interval", default: 1, range: 0.1...60)
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
    case "scan", "selftest":
        try withoutOptions()
        fail("'\(command)' is not implemented yet")
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
