// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "stupid-app",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SDKCore", targets: ["SDKCore"]),
        .library(name: "ProjectCore", targets: ["ProjectCore"]),
        .library(name: "BuildCore", targets: ["BuildCore"]),
        .library(name: "ASCKit", targets: ["ASCKit"]),
        .library(name: "SigningKit", targets: ["SigningKit"]),
        .library(name: "DeviceKit", targets: ["DeviceKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3"),
        .package(url: "https://github.com/tayloraswift/swift-png.git", from: "4.5.0"),
    ],
    targets: [
        .target(
            name: "SDKCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "ProjectCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .target(
            name: "CLZFSE",
            publicHeadersPath: "include"
        ),
        .target(
            name: "BuildCore",
            dependencies: [
                "CLZFSE",
                "ProjectCore",
                "SDKCore",
                .product(name: "PNG", package: "swift-png"),
            ]
        ),
        .target(
            name: "ASCKit",
            dependencies: [
                "SDKCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
            ]
        ),
        .target(
            name: "SigningKit",
            dependencies: [
                "ASCKit",
                "BuildCore",
                "ProjectCore",
                "SDKCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "DeviceKit",
            dependencies: [
                "BuildCore",
                "SDKCore",
            ],
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "stupid-app",
            dependencies: [
                "SDKCore",
                "ProjectCore",
                "BuildCore",
                "ASCKit",
                "SigningKit",
                "DeviceKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SDKCoreTests",
            dependencies: ["SDKCore"]
        ),
        .testTarget(
            name: "ProjectCoreTests",
            dependencies: ["ProjectCore"]
        ),
        .testTarget(
            name: "BuildCoreTests",
            dependencies: ["BuildCore", "CLZFSE"]
        ),
        .testTarget(
            name: "SigningKitTests",
            dependencies: ["SigningKit"]
        ),
        .testTarget(
            name: "ASCKitTests",
            dependencies: ["ASCKit", "SDKCore"]
        ),
        .testTarget(
            name: "DeviceKitTests",
            dependencies: ["DeviceKit"]
        ),
    ]
)
