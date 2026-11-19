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
        // Fixtures: a test certificate chain (a root, and a leaf for home.example-tailnet.ts.net valid from
        // 2026-11-19 to 2027-09-15), checked at a fixed date so the tests never expire.
        .testTarget(name: "SovereignShellTests", dependencies: ["SovereignShell"], resources: [.copy("Fixtures")]),
    ]
)
