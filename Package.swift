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
        .target(name: "AstroApplication", dependencies: ["AstroCore"]),
        .target(name: "AstroUI", dependencies: ["AstroApplication"]),
        .executableTarget(name: "astrotool", dependencies: ["AstroCore"]),
        .executableTarget(
            name: "AstroToolApp",
            dependencies: ["AstroCore", "AstroApplication", "AstroUI"]
        ),
        .testTarget(name: "AstroCoreTests", dependencies: ["AstroCore"]),
        .testTarget(
            name: "AstroApplicationTests",
            dependencies: ["AstroApplication", "AstroCore"]
        ),
        .testTarget(
            name: "AstroUITests",
            dependencies: ["AstroUI", "AstroApplication"]
        ),
    ]
)
