import Foundation
import ReportKit
import Testing

/// The line every report prints about the Mac, built from raw sysctl strings.
///
/// The awkward cases are all machines this one is not: an Intel Mac with no
/// `hw.perflevel*`, a desk Mac with no battery, a model identifier the table
/// has never seen. A parser is the only place they can be checked at all.
@Suite("System context")
struct SystemContextTests {
    private var appleSilicon: SystemContextRaw {
        SystemContextRaw(
            model: "MacBookPro18,3",
            chip: "Apple M1 Pro",
            performanceCores: 8,
            efficiencyCores: 2,
            logicalCores: 10,
            memoryBytes: 34_359_738_368,
            osVersion: "26.1",
            osBuild: "25B78",
            bootTime: Date(timeIntervalSince1970: 1_700_000_000),
            batteryPercent: 74,
            onBattery: false
        )
    }

    @Test("A MacBook Pro reads back as its family, its clusters and its build")
    func appleSiliconContext() {
        let context = SystemContextParser.context(
            from: appleSilicon,
            now: Date(timeIntervalSince1970: 1_700_000_000 + 3 * 86_400 + 4 * 3_600 + 720)
        )
        #expect(context.modelName == "MacBook Pro")
        #expect(context.modelID == "MacBookPro18,3")
        #expect(context.chip == "Apple M1 Pro")
        #expect(context.performanceCores == 8)
        #expect(context.efficiencyCores == 2)
        #expect(context.coreCount == 10)
        #expect(context.ramBytes == 34_359_738_368)
        #expect(context.osVersion == "26.1")
        #expect(context.osBuild == "25B78")
        #expect(context.uptimeSeconds == 3 * 86_400 + 4 * 3_600 + 720)
        #expect(context.batteryPercent == 74)
        #expect(context.onBattery == false)
    }

    @Test("A Mac with no cluster keys counts every logical core as one cluster")
    func intelFallback() {
        var raw = appleSilicon
        raw.model = "MacBookPro16,1"
        raw.chip = "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz"
        raw.performanceCores = 0
        raw.efficiencyCores = 0
        raw.logicalCores = 16
        let context = SystemContextParser.context(from: raw)
        // Better than "0P+0E cores", which would read as a Mac with no CPU.
        #expect(context.performanceCores == 16)
        #expect(context.efficiencyCores == 0)
        #expect(context.coreCount == 16)
    }

    @Test("A Mac with no battery says nothing about one")
    func noBattery() {
        var raw = appleSilicon
        raw.model = "Macmini9,1"
        raw.batteryPercent = nil
        raw.onBattery = nil
        let context = SystemContextParser.context(from: raw)
        #expect(context.modelName == "Mac mini")
        #expect(context.batteryPercent == nil)
        #expect(context.onBattery == nil)
    }

    @Test("Empty sysctls become words, never an empty report line")
    func emptyValues() {
        let context = SystemContextParser.context(from: SystemContextRaw())
        #expect(context.modelName == "Mac")
        #expect(context.modelID == "unknown")
        #expect(context.chip == "an unknown chip")
        #expect(context.osVersion == "unknown")
        #expect(context.osBuild == "unknown")
        #expect(context.uptimeSeconds == 0)
    }

    @Test("A clock set back since the boot gives zero uptime, never a negative one")
    func clockMovedBackwards() {
        let boot = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            SystemContextParser.uptimeSeconds(
                bootTime: boot,
                now: boot.addingTimeInterval(-3_600)
            ) == 0
        )
        #expect(SystemContextParser.uptimeSeconds(bootTime: nil, now: boot) == 0)
    }

    @Test("Every model family the table knows, and one it does not")
    func marketingNames() {
        let expected: [String: String] = [
            "MacBookPro18,3": "MacBook Pro",
            "MacBookAir10,1": "MacBook Air",
            "MacBook10,1": "MacBook",
            "Macmini9,1": "Mac mini",
            "MacPro7,1": "Mac Pro",
            "MacStudio13,1": "Mac Studio",
            "iMac21,1": "iMac",
            "iMacPro1,1": "iMac Pro",
            "Mac16,10": "Mac",
            "VirtualMac2,1": "Virtual Mac",
        ]
        for (model, name) in expected {
            #expect(SystemContextParser.marketingName(forModel: model) == name, "\(model)")
        }
        // An identifier from a Mac that does not exist yet keeps its own text
        // rather than being called something wrong.
        #expect(SystemContextParser.marketingName(forModel: "MacLaptop1,1") == "MacLaptop")
        #expect(SystemContextParser.marketingName(forModel: "") == "Mac")
    }

    @Test("The reader answers on this Mac with a line a chat model can use")
    func readsOnThisMac() {
        let context = SystemContextReader.read()
        #expect(!context.modelID.isEmpty)
        #expect(context.modelID != "unknown")
        #expect(context.ramBytes > 1_000_000_000)
        #expect(context.coreCount > 0)
        #expect(context.osVersion != "unknown")
        #expect(context.uptimeSeconds > 0)
    }

    @Test("The battery reads on this Mac, or says there is none")
    func batteryReads() {
        let status = PowerSourceReader.read()
        if let percent = status.percent {
            #expect((0...100).contains(percent))
            #expect(status.hasBattery)
        } else {
            #expect(!status.hasBattery)
        }
    }
}
