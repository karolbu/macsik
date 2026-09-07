// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macbuilder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "macbuilder", targets: ["macbuilder"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "macbuilder",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/MacBuilder"
        )
    ]
)