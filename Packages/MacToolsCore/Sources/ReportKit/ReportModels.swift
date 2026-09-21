import Foundation

/// The machine, as one line of a report. Everything here is cheap to read
/// (sysctl), so a report never waits for it.
public struct SystemContext: Sendable, Equatable, Codable {
    public let modelName: String
    public let modelID: String
    public let chip: String
    public let performanceCores: Int
    public let efficiencyCores: Int
    public let ramBytes: UInt64
    public let osVersion: String
    public let osBuild: String
    public let uptimeSeconds: Int
    public let batteryPercent: Int?
    /// Nil on a Mac without a battery.
    public let onBattery: Bool?

    public init(
        modelName: String,
        modelID: String,
        chip: String,
        performanceCores: Int,
        efficiencyCores: Int,
        ramBytes: UInt64,
        osVersion: String,
        osBuild: String,
        uptimeSeconds: Int,
        batteryPercent: Int? = nil,
        onBattery: Bool? = nil
    ) {
        self.modelName = modelName
        self.modelID = modelID
        self.chip = chip
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.ramBytes = ramBytes
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.uptimeSeconds = uptimeSeconds
        self.batteryPercent = batteryPercent
        self.onBattery = onBattery
    }

    public var coreCount: Int { performanceCores + efficiencyCores }
}

/// One process row. The counters are optional because a process can vanish
/// between the sample and the report, and a row without them is still worth
/// naming.
public struct ProcessReportRow: Sendable, Equatable, Codable, Identifiable {
    public let name: String
    public let pid: Int32
    public let user: String
    public let cpuPercent: Double?
    public let memoryBytes: UInt64?
    public let path: String?

    public init(
        name: String,
        pid: Int32,
        user: String,
        cpuPercent: Double? = nil,
        memoryBytes: UInt64? = nil,
        path: String? = nil
    ) {
        self.name = name
        self.pid = pid
        self.user = user
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.path = path
    }

    public var id: Int32 { pid }
}

public struct FileReportRow: Sendable, Equatable, Codable {
    public let name: String
    public let folder: String
    /// `st_blocks * 512`: what goes free when the file goes.
    public let allocatedBytes: UInt64
    /// `st_size`. Much larger on a sparse file or a virtual disk.
    public let logicalBytes: UInt64
    public let modified: Date

    public init(
        name: String,
        folder: String,
        allocatedBytes: UInt64,
        logicalBytes: UInt64,
        modified: Date
    ) {
        self.name = name
        self.folder = folder
        self.allocatedBytes = allocatedBytes
        self.logicalBytes = logicalBytes
        self.modified = modified
    }
}

/// The sums the process report prints above the table.
public struct ReportTotals: Sendable, Equatable, Codable {
    public let processCount: Int
    /// Per core, the way `top` counts: 250 % is two and a half busy cores.
    public let totalCPUPercent: Double
    public let memoryUsedBytes: UInt64
    public let memoryTotalBytes: UInt64
    public let swapUsedBytes: UInt64
    public let pressure: String

    public init(
        processCount: Int,
        totalCPUPercent: Double,
        memoryUsedBytes: UInt64,
        memoryTotalBytes: UInt64,
        swapUsedBytes: UInt64,
        pressure: String
    ) {
        self.processCount = processCount
        self.totalCPUPercent = totalCPUPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
    }
}

public struct StorageReportContext: Sendable, Equatable, Codable {
    public let volumeName: String
    public let usedBytes: UInt64
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let scanDate: Date
    public let filesScanned: UInt64
    /// How many rows the list in the app shows.
    public let shownCount: Int
    /// How many files the scan ranked. The list shows the top `shownCount` of
    /// these.
    public let totalInList: Int

    public init(
        volumeName: String,
        usedBytes: UInt64,
        totalBytes: UInt64,
        freeBytes: UInt64,
        scanDate: Date,
        filesScanned: UInt64,
        shownCount: Int,
        totalInList: Int
    ) {
        self.volumeName = volumeName
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.scanDate = scanDate
        self.filesScanned = filesScanned
        self.shownCount = shownCount
        self.totalInList = totalInList
    }
}

public enum TableFormat: String, Sendable, Codable, CaseIterable {
    case markdown
    case tsv
}

public struct ReportOptions: Sendable, Equatable, Codable {
    /// The paragraph that tells the chat what to do with the table.
    public let includePreamble: Bool
    public let format: TableFormat
    /// The most rows the report prints.
    public let limit: Int

    public init(includePreamble: Bool = true, format: TableFormat = .markdown, limit: Int = 60) {
        self.includePreamble = includePreamble
        self.format = format
        self.limit = limit
    }
}
