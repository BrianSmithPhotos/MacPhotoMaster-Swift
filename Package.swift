// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MacPhotoMaster",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        // Consumed as a local package dependency by MacPhotoMasterPad/ (a separate, real Xcode
        // App project — see docs/ARCHITECTURE.md "Multi-platform target split"). A bare SwiftPM
        // executableTarget can't produce a real, device-signable .app bundle for iOS, so the iPadOS
        // app itself lives outside this manifest; only the portable Core library is declared here.
        .library(name: "MacPhotoMasterCore", targets: ["MacPhotoMasterCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMajor(from: "7.0.0")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.4")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        // Portable Services/Models shared by the macOS app and the MacPhotoMasterPad iPadOS Xcode
        // project — everything except ExifToolClient.swift, which shells out via `Process` and is
        // macOS-only. See docs/ARCHITECTURE.md for the target-split rationale.
        .target(
            name: "MacPhotoMasterCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/MacPhotoMasterCore"
        ),
        .executableTarget(
            name: "MacPhotoMaster",
            dependencies: ["MacPhotoMasterCore"],
            path: "Sources/MacPhotoMaster",
            resources: [
                .copy("Resources/AppIcon.png")
            ]
        ),
        .testTarget(
            name: "MacPhotoMasterTests",
            dependencies: ["MacPhotoMaster", "MacPhotoMasterCore"],
            path: "Tests/MacPhotoMasterTests"
        )
    ],
    // Manifest format needs 6.1 for mlx-swift-lm's macro target, but the app's own code should stay
    // on Swift 5 concurrency semantics rather than pick up strict-concurrency checking as a side
    // effect of that bump.
    swiftLanguageModes: [.v5]
)
