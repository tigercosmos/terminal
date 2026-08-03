// swift-tools-version: 6.2
//
//  Package.swift
//  TerminalCore
//

import PackageDescription

// The app's logic that needs no window, so it can be exercised by `swift test`
// instead of by launching Terminal and looking at it. The build settings mirror
// the app target's — Swift 5 language mode with main-actor-by-default isolation
// — so a file moving in or out of here compiles the same way on both sides.
let package = Package(
    name: "TerminalCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TerminalCore", targets: ["TerminalCore"])
    ],
    targets: [
        .target(
            name: "TerminalCore",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "TerminalCoreTests",
            dependencies: ["TerminalCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ],
    swiftLanguageModes: [.v5]
)
