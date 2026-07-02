// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacPhotoMaster",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "MacPhotoMaster",
            path: "Sources/MacPhotoMaster"
        ),
        .testTarget(
            name: "MacPhotoMasterTests",
            dependencies: ["MacPhotoMaster"],
            path: "Tests/MacPhotoMasterTests"
        )
    ]
)
