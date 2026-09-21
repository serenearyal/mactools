// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MacToolsCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SMCKit", targets: ["SMCKit"]),
        .library(name: "FanControl", targets: ["FanControl"]),
        .library(name: "SysMetrics", targets: ["SysMetrics"]),
        .library(name: "ScanKit", targets: ["ScanKit"]),
        .library(name: "HelperProtocol", targets: ["HelperProtocol"]),
        .library(name: "WindowKit", targets: ["WindowKit"]),
        .library(name: "ReportKit", targets: ["ReportKit"]),
        .library(name: "AwakeKit", targets: ["AwakeKit"]),
        .library(name: "BacklightKit", targets: ["BacklightKit"]),
    ],
    targets: [
        .target(name: "SMCKit"),
        .target(name: "FanControl", dependencies: ["SMCKit"]),
        .target(name: "SysMetrics"),
        .target(name: "ScanKit"),
        .target(name: "HelperProtocol"),
        .target(name: "WindowKit"),
        .target(name: "ReportKit"),
        .target(name: "AwakeKit"),
        .target(name: "BacklightKit"),
        .testTarget(
            name: "MacToolsCoreTests",
            dependencies: [
                "SMCKit", "FanControl", "SysMetrics", "ScanKit", "HelperProtocol",
                "WindowKit", "ReportKit", "AwakeKit", "BacklightKit",
            ]
        ),
    ]
)
