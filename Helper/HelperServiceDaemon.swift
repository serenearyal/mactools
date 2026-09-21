import Foundation

import FanControl
import HelperProtocol
import SMCKit

extension HelperService {
    /// The service the daemon runs: the SMC of this Mac, its fans, the
    /// system-wide sleep setting, and root demanded on every privileged call.
    ///
    /// This is the only place `SMCConnection` and `SMCFanHardware` are built,
    /// and this file belongs to the helper target alone. The test target
    /// compiles `HelperService.swift` to exercise the XPC path, and with the
    /// construction of the real hardware out of that file there is no way for
    /// a test to reach a fan of the machine it runs on.
    static func daemon() -> HelperService {
        var connection: SMCConnection?
        var smcError: String?
        do {
            connection = try SMCConnection()
        } catch {
            smcError = error.description
            HelperLog.logger.error("cannot open the SMC: \(error.description, privacy: .public)")
        }

        var hardware: (any FanHardware)?
        var fanError: String?
        if let connection {
            do {
                hardware = try SMCFanHardware(smc: connection)
            } catch {
                fanError = error.description
            }
        } else {
            fanError = smcError
        }
        if let fanError {
            HelperLog.logger.error("no fan control: \(fanError, privacy: .public)")
        }

        // The real system sleep setting, with the marker file that remembers
        // whether this helper is the one that set it. Both are root-only, and
        // both exist only on this path.
        let sleep = SleepDisabledGovernor(
            power: SystemSleepSetting(),
            marker: FileSleepDisabledMarker(),
            note: { message in HelperLog.logger.notice("\(message, privacy: .public)") }
        )

        return HelperService(
            smc: connection,
            smcError: smcError,
            fanHardware: hardware,
            fanError: fanError,
            sleep: sleep,
            requiresRoot: true
        )
    }
}
