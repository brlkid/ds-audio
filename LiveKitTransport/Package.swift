// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LiveKitTransport",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "LiveKitTransport", targets: ["LiveKitTransport"])
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.5.1")
    ],
    targets: [
        .target(
            name: "LiveKitTransport",
            dependencies: [.product(name: "LiveKit", package: "client-sdk-swift")]
        )
    ]
)
