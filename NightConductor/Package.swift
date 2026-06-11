// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NightConductor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NightConductor",
            path: "Sources/NightConductor"
        ),
        .testTarget(
            name: "NightConductorTests",
            dependencies: ["NightConductor"],
            path: "Tests/NightConductorTests"
        ),
    ]
)
