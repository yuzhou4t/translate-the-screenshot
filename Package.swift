// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "tts",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "tts", targets: ["TTS"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "KeyboardShortcuts",
            path: "Sources/KeyboardShortcuts",
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        ),
        .executableTarget(
            name: "TTS",
            dependencies: [
                "KeyboardShortcuts"
            ],
            path: "Sources/TTS",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Vision")
            ]
        )
    ]
)
