// swift-tools-version: 6.2
import PackageDescription

let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "NotallyXYZ",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "NotallyCore",
            swiftSettings: settings,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "NotallyXYZ",
            dependencies: ["NotallyCore"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "NotallyCoreTests",
            dependencies: ["NotallyCore"],
            swiftSettings: settings
        ),
    ]
)
