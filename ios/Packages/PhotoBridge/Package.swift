// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoBridge",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "PhotoBridge", targets: ["PhotoBridge"]),
    ],
    targets: [
        .target(
            name: "PhotoBridge",
            path: "Sources/PhotoBridge"
        ),
    ]
)
