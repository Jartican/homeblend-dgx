// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "OmiPhoneCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "OmiPhoneCore", targets: ["OmiPhoneCore"]),
    ],
    targets: [
        .target(name: "OmiPhoneCore"),
        .testTarget(name: "OmiPhoneCoreTests", dependencies: ["OmiPhoneCore"]),
    ]
)
