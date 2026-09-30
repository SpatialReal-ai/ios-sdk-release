// swift-tools-version:5.9
// SpatialReal iOS SDK — binary distribution (SpatialRealSDK.xcframework).
// Source repository: https://github.com/SpatialReal-ai/ios-sdk
import PackageDescription

let package = Package(
    name: "SpatialRealSDK",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "SpatialRealSDK",
            targets: ["SpatialRealSDK"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "SpatialRealSDK",
            url: "https://github.com/SpatialReal-ai/ios-sdk-release/releases/download/v1.0.0-beta.1/SpatialRealSDK_202609292249.zip",
            checksum: "fc97b7130570b4b1e0e0c57baa2a8151a602272919c7a0951f6f1c19ada0810e"
        )
    ]
)
