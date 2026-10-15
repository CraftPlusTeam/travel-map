// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TravelMapCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "TravelMapCore", targets: ["TravelMapCore"])],
    targets: [
        .target(name: "TravelMapCore", path: "TravelMapCore"),
        .testTarget(name: "TravelMapCoreTests", dependencies: ["TravelMapCore"], path: "Tests")
    ]
)
