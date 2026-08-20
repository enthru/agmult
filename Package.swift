// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgilentDMM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgilentDMM", targets: ["AgilentDMM"]),
        .library(name: "AgilentDMMKit", targets: ["AgilentDMMKit"]),
        .executable(name: "agmult-sim", targets: ["agmult-sim"]),
        .library(name: "DMMCore", targets: ["DMMCore"]),
        .library(name: "DMMSimulator", targets: ["DMMSimulator"]),
    ],
    targets: [
        .target(name: "DMMCore"),
        .target(name: "DMMSimulator", dependencies: ["DMMCore"]),
        .executableTarget(name: "agmult-sim", dependencies: ["DMMSimulator"]),
        .target(name: "AgilentDMMKit", dependencies: ["DMMCore", "DMMSimulator"]),
        .executableTarget(name: "AgilentDMM", dependencies: ["AgilentDMMKit"]),
        .testTarget(name: "DMMCoreTests", dependencies: ["DMMCore", "DMMSimulator", "AgilentDMMKit"]),
    ],
    swiftLanguageModes: [.v5]
)
