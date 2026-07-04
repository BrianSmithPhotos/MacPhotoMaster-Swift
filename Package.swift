// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MacPhotoMaster",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMajor(from: "7.0.0")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.4")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "MacPhotoMaster",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/MacPhotoMaster",
            resources: [
                .copy("Resources/AppIcon.png")
            ]
        ),
        .testTarget(
            name: "MacPhotoMasterTests",
            dependencies: ["MacPhotoMaster"],
            path: "Tests/MacPhotoMasterTests"
        )
    ],
    // Manifest format needs 6.1 for mlx-swift-lm's macro target, but the app's own code should stay
    // on Swift 5 concurrency semantics rather than pick up strict-concurrency checking as a side
    // effect of that bump.
    swiftLanguageModes: [.v5]
)
