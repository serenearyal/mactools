import Foundation

import HelperProtocol

let usage = """
ventctl - debug CLI for Vent (protocol \(HelperConstants.protocolVersion))

usage: ventctl <command>

commands:
  dump-keys    list every SMC key with its type, size, attributes and value
  sensors      print the live temperature sensors by category
  fans         print fan state and limits
  power        print the power sensors
  watch        stream sensors and fans
  procs        print the process table
  io           print disk I/O throughput
  scan         run the largest-files scan
  helper-ping  check the privileged helper
  selftest     run the fan safety sequence
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ventctl: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments.dropFirst()
guard let command = arguments.first else {
    print(usage)
    exit(0)
}
guard arguments.count == 1 else {
    fail("'\(command)' takes no argument")
}

do {
    switch command {
    case "dump-keys": try SMCCommands.dumpKeys()
    case "sensors": try SMCCommands.sensors()
    case "fans": try SMCCommands.fans()
    case "power": try SMCCommands.power()
    case "watch", "procs", "io", "scan", "helper-ping", "selftest":
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
