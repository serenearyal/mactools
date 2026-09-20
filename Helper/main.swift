import Foundation

import HelperProtocol

// The privileged helper. launchd owns its lifetime: the daemon is started on
// demand for the mach service and stays until the machine shuts down, so the
// process has no idle timer of its own. The fan governor needs that, because
// it keeps ticking between calls.
let service = HelperService.daemon()

// Order matters. Every fan is put back under firmware control (guarantee 3)
// and the ways out are armed (guarantee 2) before the first client can ask
// for anything.
service.fans?.installTerminationHandlers()
service.fans?.startWithAutoRestore()

let delegate = HelperListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
HelperListenerDelegate.applyClientRequirement(to: listener)
listener.resume()

HelperLog.logger.notice(
    """
    helper \(HelperBuild.version, privacy: .public) listening on \
    \(HelperConstants.machServiceName, privacy: .public), euid \(geteuid(), privacy: .public)
    """
)

dispatchMain()
