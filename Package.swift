// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Rushes",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Rushes", targets: ["Rushes"]),
        .executable(name: "RushesChecks", targets: ["RushesChecks"]),
    ],
    targets: [
        // Everything that can be tested without a window: the ledger, the copier, the reader of
        // DaVinci Resolve's project files, the matching of paths.
        .target(
            name: "RushesKit",
            path: "Sources/RushesKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Rushes",
            dependencies: ["RushesKit"],
            path: "Sources/Rushes",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Checks of the kit. A plain program because Swift Testing and XCTest need a full Xcode.
        .executableTarget(
            name: "RushesChecks",
            dependencies: ["RushesKit"],
            path: "Sources/RushesChecks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
