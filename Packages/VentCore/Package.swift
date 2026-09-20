// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "VentCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SMCKit", targets: ["SMCKit"]),
        .library(name: "FanControl", targets: ["FanControl"]),
        .library(name: "SysMetrics", targets: ["SysMetrics"]),
        .library(name: "ScanKit", targets: ["ScanKit"]),
        .library(name: "HelperProtocol", targets: ["HelperProtocol"]),
    ],
    targets: [
        .target(name: "SMCKit"),
        .target(name: "FanControl", dependencies: ["SMCKit"]),
        .target(name: "SysMetrics"),
        .target(name: "ScanKit"),
        .target(name: "HelperProtocol"),
        .testTarget(
            name: "VentCoreTests",
            dependencies: ["SMCKit", "FanControl", "SysMetrics", "ScanKit", "HelperProtocol"]
        ),
    ]
)
