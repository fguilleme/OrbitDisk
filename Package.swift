// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OrbitDisk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OrbitDisk", targets: ["OrbitDisk"])
    ],
    targets: [
        .executableTarget(name: "OrbitDisk"),
        .testTarget(name: "OrbitDiskTests", dependencies: ["OrbitDisk"])
    ]
)
