# SpatialReal iOS SDK

Photorealistic avatars that speak in real time, rendered on the device. This repository distributes the prebuilt SpatialReal iOS SDK (`SpatialRealSDK`).

Docs: [iOS SDK](https://docs.spatialreal.ai/sdk-reference/ios-sdk/introduction)

## Installation

### Swift Package Manager

In Xcode, choose **File → Add Package Dependencies…**, enter `https://github.com/SpatialReal-ai/ios-sdk-release.git`, and add the **SpatialRealSDK** product to your app target. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/SpatialReal-ai/ios-sdk-release.git", from: "1.0.0-beta.3")
],
targets: [
    .target(name: "YourApp", dependencies: [.product(name: "SpatialRealSDK", package: "ios-sdk-release")])
]
```

### LiveKit route

If your agent runs in a LiveKit room (for example with [livekit-plugins-spatialreal](https://github.com/SpatialReal-ai/livekit-plugins-spatialreal)), add the **SpatialRealLiveKit** product as well. It is a source target in this package: it depends on `SpatialRealSDK` and on [livekit/client-sdk-swift](https://github.com/livekit/client-sdk-swift), so only add it when you need it.

```swift
.target(name: "YourApp", dependencies: [
    .product(name: "SpatialRealSDK", package: "ios-sdk-release"),
    .product(name: "SpatialRealLiveKit", package: "ios-sdk-release")
])
```

```swift
import SpatialRealLiveKit

let session = try await sr.createSession(LiveKitAvatarSessionOptions(
    avatarId: avatarId, credential: sessionToken, container: containerView,
    livekit: LiveKitConnection(url: livekitURL, token: livekitToken)))
try await session.start()      // joins the room; the avatar's audio and animation arrive on its tracks
```

The LiveKit route is SwiftPM only (not in the CocoaPods spec).

### CocoaPods

```ruby
pod 'SpatialRealSDK', :podspec => 'https://raw.githubusercontent.com/SpatialReal-ai/ios-sdk-release/main/SpatialRealSDK.podspec'
```

### XCFramework

Download `SpatialRealSDK.xcframework` from [Releases](https://github.com/SpatialReal-ai/ios-sdk-release/releases), drag it into your Xcode project, and set it to **Embed & Sign** under your target's **Frameworks, Libraries, and Embedded Content**.

## Requirements

- iOS 16.0 or later, on an A11 chip or newer; the simulator works on a Mac with Apple silicon, for everything except the microphone
- Xcode 16 or later (Swift 6)

## Getting started

You need an App ID and a session token from [SpatialReal Studio](https://app.spatialreal.ai). Your server exchanges its API key for session tokens; the API key never goes into the app.

- [SDK mode on iOS](https://docs.spatialreal.ai/avatar-integration/sdk-mode/ios): an avatar that speaks audio your app has
- [Your own app](https://docs.spatialreal.ai/agent/reach/your-own-app): a conversation with a SpatialReal Agent
- [API reference](https://docs.spatialreal.ai/sdk-reference/ios-sdk/api-reference)
- [Examples](https://github.com/SpatialReal-ai/spatialreal-examples)
