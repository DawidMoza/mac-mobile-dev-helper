// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "mac-mobile-dev-helper",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MobileDevHelper", targets: ["MobileDevHelper"])
    ],
    targets: [
        .executableTarget(
            name: "MobileDevHelper",
            path: "Sources/MobileDevHelper"
        ),
        .testTarget(
            name: "MobileDevHelperTests",
            dependencies: ["MobileDevHelper"],
            path: "Tests/MobileDevHelperTests"
        )
    ]
)
