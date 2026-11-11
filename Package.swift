// swift-tools-version:5.9
// SpatialReal iOS SDK — binary distribution (SpatialRealSDK.xcframework).
// Source repository: https://github.com/SpatialReal-ai/ios-sdk
//
// Products:
//   SpatialRealSDK      the SDK (prebuilt xcframework)
//   SpatialRealLiveKit  the LiveKit route (source; depends on SpatialRealSDK and livekit/client-sdk-swift).
//                       Add it only if your agent runs in a LiveKit room: it pulls LiveKit into your app.
//   SpatialRealAgora    the Agora route (source; depends on SpatialRealSDK and AgoraIO/AgoraRtcEngine_iOS, product RtcBasic).
//                       Add it only if the avatar is published into an Agora channel: it pulls Agora into your app.
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
        ),
        .library(
            name: "SpatialRealAgora",
            targets: ["SpatialRealAgora"]
        )
    ],
    dependencies: [
        // client-sdk-swift 2.16+ manifests need swift-tools 6.1 (Xcode 16.3+); widen once that is the floor
        .package(url: "https://github.com/livekit/client-sdk-swift.git", "2.14.0"..<"2.16.0"),
        // RtcBasic is the smallest Agora product with video and the encoded-frame callback
        .package(url: "https://github.com/AgoraIO/AgoraRtcEngine_iOS.git", "4.6.4"..<"4.7.0")
    ],
    targets: [
        .binaryTarget(
            name: "SpatialRealSDK",
            url: "https://github.com/SpatialReal-ai/ios-sdk-release/releases/download/v1.0.0-beta.7/SpatialRealSDK_202611101850.zip",
            checksum: "7ad1128310797e1b8013c42c3f1f4f9a4c0ce21553457d7d79a5fb565a51969e"
        ),
        .target(
            name: "SpatialRealLiveKit",
            dependencies: [
                "SpatialRealSDK",
                .product(name: "LiveKit", package: "client-sdk-swift")
            ],
            path: "Sources/SpatialRealLiveKit"
        ),
        .target(
            name: "SpatialRealAgoraSEI",
            dependencies: ["SpatialRealSDK"],
            path: "Sources/SpatialRealAgoraSEI"
        ),
        .target(
            name: "SpatialRealAgora",
            dependencies: [
                "SpatialRealSDK",
                "SpatialRealAgoraSEI",
                .product(name: "RtcBasic", package: "AgoraRtcEngine_iOS")
            ],
            path: "Sources/SpatialRealAgora"
        )
    ]
)
