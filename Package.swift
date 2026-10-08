// swift-tools-version:5.9
// SpatialReal iOS SDK — binary distribution (SpatialRealSDK.xcframework).
// Source repository: https://github.com/SpatialReal-ai/ios-sdk
//
// Products:
//   SpatialRealSDK      the SDK (prebuilt xcframework)
//   SpatialRealLiveKit  the LiveKit route (source; depends on SpatialRealSDK and livekit/client-sdk-swift).
//                       Add it only if your agent runs in a LiveKit room: it pulls LiveKit into your app.
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
        ),
        .library(
            name: "SpatialRealLiveKit",
            targets: ["SpatialRealLiveKit"]
        )
    ],
    dependencies: [
        // client-sdk-swift 2.16+ manifests need swift-tools 6.1 (Xcode 16.3+); widen once that is the floor
        .package(url: "https://github.com/livekit/client-sdk-swift.git", "2.14.0"..<"2.16.0")
    ],
    targets: [
        .binaryTarget(
            name: "SpatialRealSDK",
            url: "https://github.com/SpatialReal-ai/ios-sdk-release/releases/download/v1.0.0-beta.3/SpatialRealSDK_202610072318.zip",
            checksum: "8b67c7fdafe5cd92134ef8770c1909f11c77446a884860d7cab393b6f982e40e"
        ),
        .target(
            name: "SpatialRealLiveKit",
            dependencies: [
                "SpatialRealSDK",
                .product(name: "LiveKit", package: "client-sdk-swift")
            ],
            path: "Sources/SpatialRealLiveKit"
        )
    ]
)
