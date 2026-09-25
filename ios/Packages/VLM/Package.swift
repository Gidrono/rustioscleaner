// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VLM",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "VLM", targets: ["VLM"]),
    ],
    targets: [
        .target(
            name: "VLM",
            path: "Sources/VLM"
        ),
    ]
)
