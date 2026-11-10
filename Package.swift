// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TankMini",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TankMiniCore"),
        .executableTarget(name: "tankctl", dependencies: ["TankMiniCore"]),
        .executableTarget(name: "TankMiniApp", dependencies: ["TankMiniCore"]),
    ]
)
