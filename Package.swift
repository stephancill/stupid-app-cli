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
    .library(name: "ProductCore", targets: ["ProductCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-asn1.git", from: "1.7.1"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3"),
    .package(url: "https://github.com/tayloraswift/swift-png.git", from: "4.5.0"),
  ],
  targets: [
    .target(
      name: "SDKCore",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .target(
      name: "ProjectCore",
      dependencies: [
        .product(name: "Yams", package: "Yams")
      ]
    ),
    .target(
      name: "CLZFSE",
      publicHeadersPath: "include"
    ),
    .systemLibrary(
      name: "COpenSSL",
      pkgConfig: "openssl",
      providers: [
        .apt(["libssl-dev"]),
        .brew(["openssl@3"]),
      ]
    ),
    .target(
      name: "CCoreDeviceTLS",
      dependencies: ["COpenSSL", "CTUN"],
      publicHeadersPath: "include"
    ),
    .target(
      name: "CLockdownTLS",
      dependencies: ["COpenSSL", "CTUN"],
      publicHeadersPath: "include"
    ),
    .target(
      name: "CTUN",
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
        .product(name: "SwiftASN1", package: "swift-asn1"),
        .product(name: "_CryptoExtras", package: "swift-crypto"),
        .product(name: "X509", package: "swift-certificates"),
      ],
      resources: [
        .copy("Resources/AppleIncRootCertificate.pem"),
        .copy("Resources/AppleWWDRCAG3.pem"),
      ]
    ),
    .target(
      name: "DeviceKit",
      dependencies: [
        "BuildCore",
        "CCoreDeviceTLS",
        "CLockdownTLS",
        "CTUN",
        "SDKCore",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "_CryptoExtras", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "ProductCore",
      dependencies: [
        "ASCKit",
        "BuildCore",
        "DeviceKit",
        "ProjectCore",
        "SDKCore",
        "SigningKit",
      ]
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
        "ProductCore",
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
      dependencies: [
        "SigningKit",
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "_CryptoExtras", package: "swift-crypto"),
        .product(name: "X509", package: "swift-certificates"),
      ]
    ),
    .testTarget(
      name: "ASCKitTests",
      dependencies: ["ASCKit", "SDKCore"]
    ),
    .testTarget(
      name: "DeviceKitTests",
      dependencies: [
        "DeviceKit",
        "CTUN",
        .product(name: "_CryptoExtras", package: "swift-crypto"),
      ]
    ),
    .testTarget(
      name: "ProductCoreTests",
      dependencies: ["ProductCore"]
    ),
  ]
)
