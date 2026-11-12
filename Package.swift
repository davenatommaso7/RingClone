// swift-tools-version:6.0
// RingCore: logica pura (solo Foundation). Compila e si testa su macOS, iOS, watchOS e Linux:  swift test
import PackageDescription

let package = Package(
    name: "RingCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [.library(name: "RingCore", targets: ["RingCore"])],
    targets: [
        .target(name: "RingCore", path: "Sources/RingCore"),
        .testTarget(name: "RingCoreTests", dependencies: ["RingCore"], path: "Tests/RingCoreTests"),
    ],
    swiftLanguageModes: [.v6]
)
