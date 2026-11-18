// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SovereignShell",
    // macOS is listed so the model tests run with `swift test` on a Mac; the app is iOS-only.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SovereignShell", targets: ["SovereignShell"]),
    ],
    targets: [
        .target(name: "SovereignShell"),
        .testTarget(name: "SovereignShellTests", dependencies: ["SovereignShell"]),
    ]
)
