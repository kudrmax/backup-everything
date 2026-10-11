// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackupCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackupCore", targets: ["BackupCore"]),
        .executable(name: "backup-receiver", targets: ["backup-receiver"]),
    ],
    targets: [
        .target(name: "BackupCore"),
        .target(name: "ReceiverGate"),
        .executableTarget(name: "backup-receiver", dependencies: ["ReceiverGate"]),
        .testTarget(name: "BackupCoreTests", dependencies: ["BackupCore"]),
        .testTarget(name: "ReceiverGateTests", dependencies: ["ReceiverGate"]),
    ]
)
