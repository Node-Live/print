// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NodePrint",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NodePrintCore"),
        .executableTarget(name: "NodePrintApp", dependencies: ["NodePrintCore"]),
        .testTarget(name: "NodePrintCoreTests", dependencies: ["NodePrintCore"]),
    ]
)
