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
        // The privacy manifest is a resource so that it ships inside the package and reaches every app's privacy
        // report. Xcode does not treat an .xcprivacy file as a resource unless it is declared here.
        .target(name: "TraceSDK", resources: [.process("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "TraceSDKTests", dependencies: ["TraceSDK"]),
    ]
)
