import Foundation

import HelperProtocol

// The privileged helper. launchd owns its lifetime: the daemon is started on
// demand for the mach service and stays until the machine shuts down, so the
// process has no idle timer of its own. Later batches need that, because the
// fan governor must keep running while no client is connected.
let service = HelperService()
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
