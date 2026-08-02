// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Astro-Tool",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AstroCore", targets: ["AstroCore"]),
        .executable(name: "astrotool", targets: ["astrotool"]),
        .executable(name: "AstroToolApp", targets: ["AstroToolApp"]),
    ],
    targets: [
        .target(name: "AstroCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "astrotool", dependencies: ["AstroCore"]),
        .executableTarget(name: "AstroToolApp", dependencies: ["AstroCore"]),
        .testTarget(name: "AstroCoreTests", dependencies: ["AstroCore"]),
    ]
)
