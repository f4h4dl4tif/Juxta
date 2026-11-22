// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Juxta",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Juxta", targets: ["Juxta"]),
        .library(name: "JuxtaCore", targets: ["JuxtaCore"]),
    ],
    targets: [
        // Platform-neutral comparison engines: line/char diff, 3-way merge, text decoding, CSV, folder scanning.
        .target(name: "JuxtaCore"),
        // SwiftUI + AppKit app.
        .executableTarget(name: "Juxta", dependencies: ["JuxtaCore"]),
        .testTarget(name: "JuxtaCoreTests", dependencies: ["JuxtaCore"]),
    ],
    swiftLanguageModes: [.v5]
)
