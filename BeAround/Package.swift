// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BeAround",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "BeAround",
            targets: ["BeAround"]
        ),
    ],
    targets: [
        .target(
            name: "BeAround"
        ),
    ]
)
