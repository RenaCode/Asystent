// swift-tools-version: 6.0
// Rdzeń agenta (bez UIKit/EventKit/HomeKit) jako pakiet — testy jednostkowe na macOS
// bez symulatora: `swift test`. Aplikacja kompiluje te same pliki przez project.yml.
import PackageDescription

let package = Package(
    name: "AsystentCore",
    platforms: [.macOS(.v14), .iOS(.v18)],
    products: [.library(name: "AsystentCore", targets: ["AsystentCore"])],
    targets: [
        .target(
            name: "AsystentCore",
            path: "Sources",
            exclude: ["App", "Intents", "Settings", "Voice", "Tools/CalendarTools.swift",
                      "Tools/HomeKitTool.swift", "Tools/RunShortcutTool.swift", "Tools/DefaultTools.swift"],
            sources: ["Agent", "Tools/ToolRegistry.swift"]
        ),
        .testTarget(
            name: "AsystentTests",
            dependencies: ["AsystentCore"],
            path: "Tests/AsystentTests"
        ),
    ]
)
