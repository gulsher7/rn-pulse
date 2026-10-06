// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RNPulse",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "RNPulse",
            targets: ["RNPulse"]
        )
    ],
    targets: [
        .executableTarget(
            name: "RNPulse",
            path: "Sources/RNPulse"
        )
    ]
)
