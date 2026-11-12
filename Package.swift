// swift-tools-version:5.9
// SpatialReal iOS SDK — binary distribution (SpatialRealSDK.xcframework).
//
// Products:
//   SpatialRealSDK      the SDK (prebuilt xcframework)
//   SpatialRealLiveKit  the LiveKit route (source; depends on SpatialRealSDK and livekit/client-sdk-swift).
//                       Add it only if your agent runs in a LiveKit room: it pulls LiveKit into your app.
//   SpatialRealAgora    the Agora route (source; depends on SpatialRealSDK and AgoraIO/AgoraRtcEngine_iOS, product RtcBasic).
//                       Add it only if the avatar is published into an Agora channel: it pulls Agora into your app.
//   SpatialRealPipecat  the Pipecat route (source; depends on SpatialRealSDK, pipecat-ai/pipecat-client-ios-daily and
//                       apple/swift-protobuf). Add it only if your Pipecat bot runs the pipecat-spatialreal processor
//                       over Daily: it pulls Pipecat and Daily into your app.
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
        ),
        .library(
            name: "SpatialRealPipecat",
            targets: ["SpatialRealPipecat"]
        )
    ],
    dependencies: [
        // client-sdk-swift 2.16+ manifests need swift-tools 6.1 (Xcode 16.3+); widen once that is the floor
        .package(url: "https://github.com/livekit/client-sdk-swift.git", "2.14.0"..<"2.16.0"),
        // RtcBasic is the smallest Agora product with video and the encoded-frame callback
        .package(url: "https://github.com/AgoraIO/AgoraRtcEngine_iOS.git", "4.6.4"..<"4.7.0"),
        // brings PipecatClientIOS and daily-client-ios
        .package(url: "https://github.com/pipecat-ai/pipecat-client-ios-daily.git", "1.3.0"..<"2.0.0"),
        // the Pipecat route decodes the bot's avatar messages with generated protobuf code
        .package(url: "https://github.com/apple/swift-protobuf.git", "1.30.0"..<"2.0.0")
    ],
    targets: [
        .binaryTarget(
            name: "SpatialRealSDK",
            url: "https://github.com/SpatialReal-ai/ios-sdk-release/releases/download/v1.0.0-beta.9/SpatialRealSDK_202611121014.zip",
            checksum: "9a270eec0409e392132a43db68f12a50fc85926f985220f13f5952b9dc724bdf"
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
        ),
        .target(
            name: "SpatialRealPipecat",
            dependencies: [
                "SpatialRealSDK",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "PipecatClientIOSDaily", package: "pipecat-client-ios-daily")
            ],
            path: "Sources/SpatialRealPipecat"
        )
    ]
)
