// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TeamTalkKit",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "TeamTalkKit",
            targets: ["TeamTalkKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.5.1")
    ],
    targets: [
        .target(
            name: "TeamTalkC",
            publicHeadersPath: "include"),
        .target(
            name: "TeamTalkKit",
            dependencies: [
                "TeamTalkC",
                .product(name: "LiveKit", package: "client-sdk-swift")
            ])
    ]
)
