Pod::Spec.new do |spec|
  spec.name         = "SpatialRealSDK"
  spec.version      = "1.0.0-beta.1"
  spec.summary      = "SpatialReal iOS SDK - real-time avatar rendering, driving and voice chat"
  spec.description  = <<-DESC
                      SpatialRealSDK is a high-performance avatar rendering SDK that provides real-time rendering,
                      audio-driven animation and managed voice chat against the SpatialReal platform.
                      Binary distribution (SpatialRealSDK.xcframework: ios-arm64 + ios-arm64-simulator).
                      DESC
  spec.homepage     = "https://github.com/SpatialReal-ai/ios-sdk-release"
  spec.license      = { :type => "MIT" }
  spec.author       = { "SpatialReal" => "dev@spatialreal.ai" }
  spec.platform     = :ios, "16.0"
  spec.ios.deployment_target = "16.0"
  spec.swift_version = "6.0"
  spec.source       = {
    :http => "https://github.com/SpatialReal-ai/ios-sdk-release/releases/download/v1.0.0-beta.1/SpatialRealSDK_202609292249.zip",
    :type => "zip",
    :sha256 => "fc97b7130570b4b1e0e0c57baa2a8151a602272919c7a0951f6f1c19ada0810e"
  }
  spec.vendored_frameworks = "SpatialRealSDK.xcframework"
  spec.frameworks = [
    'Foundation',
    'UIKit',
    'Metal',
    'MetalKit',
    'CoreML',
    'Accelerate',
    'AVFoundation',
    'AudioToolbox',
    'CoreGraphics',
    'CoreVideo'
  ]
  spec.libraries = [
    'c++',
    'z'
  ]
  # The xcframework ships arm64 device + arm64 simulator slices only (no x86_64 simulator).
  spec.pod_target_xcconfig  = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'x86_64' }
  spec.user_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'x86_64' }
end
