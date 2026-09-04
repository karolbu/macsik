// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacBuilder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "macbuilder", targets: ["MacBuilder"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0")
    ],
    targets: [
        .executableTarget(
            name: "MacBuilder",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/MacBuilder"
        )
    ]
)