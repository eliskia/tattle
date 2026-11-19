// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tattle",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tattle",
            path: "Sources/Tattle",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
