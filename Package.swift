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
            url: "https://github.com/SpatialReal-ai/ios-sdk-release/releases/download/v1.0.0-beta.2/SpatialRealSDK_202609302105.zip",
            checksum: "59e05f660faffa85ed90e38796517d6c90504718eb7a251f90f1f0d6364717fb"
        )
    ]
)
