import Foundation

import HelperProtocol

// Skeleton helper. The XPC listener, the fan governor and the restore-Auto
// paths arrive in a later batch. For now it only reports what it is, so the
// embedding, the signature and the LaunchDaemon plist can be checked.
let version = "\(HelperConstants.helperBundleIdentifier) protocol \(HelperConstants.protocolVersion)"
print(version)
