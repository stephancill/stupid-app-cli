// swift-tools-version: 6.0
import PackageDescription

// Open replacements for the macro plugins Xcode ships only as macOS binaries
// (SwiftUIMacros, SwiftDataMacros, PreviewsMacros), so iOS apps that use `@State`,
// `@Entry`, `@Model` or `#Preview` build on Linux with an exported Xcode SDK. The
// compiler loads the executable with
// `-load-plugin-executable <path>#SwiftUIMacros,SwiftDataMacros,PreviewsMacros`.
let package = Package(
  name: "StupidAppMacros",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "stupid-app-macros", targets: ["StupidAppMacros"])],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0")
  ],
  targets: [
    .target(
      name: "VendoredFoundationMacros",
      dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
        .product(name: "SwiftDiagnostics", package: "swift-syntax"),
        .product(name: "SwiftIfConfig", package: "swift-syntax"),
        .product(name: "SwiftOperators", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
      ],
      exclude: ["LICENSE.md", "README.md"],
      swiftSettings: [
        .define("FOUNDATION_FRAMEWORK"),
        .enableExperimentalFeature("AccessLevelOnImport"),
      ]
    ),
    .executableTarget(
      name: "StupidAppMacros",
      dependencies: [
        "VendoredFoundationMacros",
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
      ]
    ),
    .testTarget(
      name: "StupidAppMacrosTests",
      dependencies: [
        "StupidAppMacros",
        .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
      ]
    ),
  ]
)
