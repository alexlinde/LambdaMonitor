// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LambdaMonitor",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .target(
            name: "LambdaMonitorCore",
            path: "Sources/Core",
            resources: [
                .process("../../Resources")
            ]
        ),
        .executableTarget(
            name: "LambdaMonitor",
            dependencies: ["LambdaMonitorCore"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "LambdaMonitorTests",
            dependencies: ["LambdaMonitorCore"],
            path: "Tests"
        )
    ]
)
