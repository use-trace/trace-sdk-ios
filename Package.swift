// swift-tools-version:6.0
import PackageDescription

// macOS is here only so the core tests run on the Mac with `swift test`. The SDK ships for iOS.
let package = Package(
    name: "TraceSDK",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TraceSDK", targets: ["TraceSDK"]),
    ],
    targets: [
        .target(name: "TraceSDK"),
        .testTarget(name: "TraceSDKTests", dependencies: ["TraceSDK"]),
    ]
)
