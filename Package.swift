// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DevScope",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "DevScope", path: "Sources/DevScope"),
        .testTarget(name: "DevScopeTests", dependencies: ["DevScope"])
    ]
)
