import Foundation

import HelperProtocol

// Skeleton CLI. The subcommands arrive with the modules they drive.
let usage = """
ventctl - debug CLI for Vent (protocol \(HelperConstants.protocolVersion))

usage: ventctl <command>

commands:
  dump-keys    list every SMC key
  sensors      print the named temperature and power sensors
  fans         print fan state and limits
  watch        stream sensors and fans
  procs        print the process table
  io           print disk I/O throughput
  scan         run the largest-files scan
  helper-ping  check the privileged helper
  selftest     run the fan safety sequence

No command is implemented yet in this skeleton build.
"""

print(usage)
exit(CommandLine.arguments.count > 1 ? 1 : 0)
