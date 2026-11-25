// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProteusKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ProteusKit", targets: ["ProteusKit"]),
        .executable(name: "proteus-probe", targets: ["proteus-probe"]),
    ],
    targets: [
        .target(
            name: "ProteusKit",
            resources: [.copy("Resources/palettes.json")]
        ),
        .executableTarget(
            name: "proteus-probe",
            dependencies: ["ProteusKit"]
        ),
        .testTarget(
            name: "ProteusKitTests",
            dependencies: ["ProteusKit"]
        ),
    ],
    // The package is shared with the SwiftUI app, whose concurrency model is
    // MainActor-based. Swift 5 language mode keeps the stores simple classes
    // on both Linux and Apple platforms without Sendable churn.
    swiftLanguageModes: [.v5]
)
