// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackupCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackupCore", targets: ["BackupCore"]),
    ],
    targets: [
        .target(name: "BackupCore"),
        .testTarget(
            name: "BackupCoreTests",
            dependencies: ["BackupCore"]
        ),
    ]
)
