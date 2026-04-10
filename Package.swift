// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LambdaMonitor",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "LambdaMonitor",
            path: "Sources",
            resources: [
                .process("../Resources")
            ]
        )
    ]
)
