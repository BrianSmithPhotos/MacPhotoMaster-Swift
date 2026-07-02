// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacPhotoMaster",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", .upToNextMajor(from: "7.0.0"))
    ],
    targets: [
        .executableTarget(
            name: "MacPhotoMaster",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/MacPhotoMaster"
        ),
        .testTarget(
            name: "MacPhotoMasterTests",
            dependencies: ["MacPhotoMaster"],
            path: "Tests/MacPhotoMasterTests"
        )
    ]
)
