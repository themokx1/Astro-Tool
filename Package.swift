// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Astro-Tool",
    defaultLocalization: "en",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "AstroCore", targets: ["AstroCore"]),
        .library(name: "AstroApplication", targets: ["AstroApplication"]),
        .library(name: "AstroMobileDomain", targets: ["AstroMobileDomain"]),
        .library(name: "AstroUI", targets: ["AstroUI"]),
        .executable(name: "astrotool", targets: ["astrotool"]),
        .executable(name: "AstroToolApp", targets: ["AstroToolApp"]),
    ],
    targets: [
        .target(name: "AstroCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "AstroApplication", dependencies: ["AstroCore", "AstroMobileDomain"]),
        .target(name: "AstroMobileDomain"),
        .target(
            name: "AstroUI",
            dependencies: ["AstroApplication"],
            linkerSettings: [.linkedFramework("WebKit"), .linkedFramework("PDFKit")]
        ),
        .executableTarget(name: "astrotool", dependencies: ["AstroCore"]),
        .executableTarget(
            name: "AstroToolApp",
            dependencies: ["AstroCore", "AstroApplication", "AstroUI"],
            resources: [.process("Resources")]
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
        .testTarget(name: "AstroMobileDomainTests", dependencies: ["AstroMobileDomain"]),
    ]
)
