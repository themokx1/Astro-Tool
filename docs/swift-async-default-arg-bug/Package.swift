// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "minrepro", platforms: [.macOS(.v26)],
    targets: [.target(name: "LibA"), .executableTarget(name: "AppB", dependencies: ["LibA"])]
)
