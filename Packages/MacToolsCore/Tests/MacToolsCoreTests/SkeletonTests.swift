import Testing

import FanControl
import HelperProtocol
import ScanKit
import SMCKit
import SysMetrics

@Test("every MacToolsCore module is linked and exports its namespace")
func modulesAreLinked() {
    #expect(SMC.serviceName == "AppleSMC")
    #expect(Fans.thermalInterlockCelsius == 100)
    #expect(Metrics.defaultSampleInterval == 1)
    #expect(Scan.resultLimit == 500)
    #expect(HelperConstants.machServiceName == "com.serenearyal.mactools.helper")
}
