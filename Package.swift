// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "ParkifyRules", platforms: [.macOS(.v13), .iOS(.v17)],
    targets: [.target(name: "ParkifyRules", path: "Shared"),
              .testTarget(name: "ParkingTests", dependencies: ["ParkifyRules"], path: "Tests")])
