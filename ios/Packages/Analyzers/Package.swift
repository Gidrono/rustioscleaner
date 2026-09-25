// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Analyzers",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "Analyzers", targets: ["Analyzers"]),
    ],
    targets: [
        .target(
            name: "Analyzers",
            path: "Sources/Analyzers"
        ),
    ]
)
