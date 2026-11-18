// swift-tools-version:6.2
// Lets you open the project in Xcode (File > Open > this folder) or run `swift run RAMWatch --dump`.
// Use ./build.sh to produce the actual .app bundle.
import PackageDescription

let package = Package(
    name: "RAMWatch",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "RAMWatch",
            path: "Sources/RAMWatch",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
