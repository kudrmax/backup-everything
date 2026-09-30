// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackupEverything",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../BackupCore"),
    ],
    targets: [
        .executableTarget(
            name: "BackupEverything",
            dependencies: ["BackupCore"]
        ),
        .testTarget(
            name: "BackupEverythingTests",
            dependencies: ["BackupEverything"]
        ),
    ]
)
