import Foundation
import ProjectCore
import SDKCore
import Testing

@testable import BuildCore

/// Binary targets are accepted only as local XCFrameworks of static archives with an arm64 slice
/// for the build's platform. The planner reads the XCFramework's Info.plist; the end-to-end case
/// links a real static library into a built app.
struct StaticXCFrameworkTests {
  private let config = AppConfig(
    version: 1, product: "BinApp", bundleID: "net.example.bin-app",
    deploymentTarget: "17.0", infoPath: "Info.plist")

  @Test("accepts a static-library XCFramework with a slice for the platform")
  func acceptsStaticLibraries() throws {
    let root = try fixtureRoot(libraries: [
      library(path: "libdemo.a", variant: nil),
      library(path: "libdemo.a", variant: "simulator"),
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    try planner(root: root, platform: .device).validateStaticXCFramework(
      name: "Demo", path: "Demo.xcframework")
    try planner(root: root, platform: .simulator).validateStaticXCFramework(
      name: "Demo", path: "Demo.xcframework")
  }

  @Test("rejects a dynamic framework, a missing platform slice, and non-local binaries")
  func rejectsUnsupportedBinaries() throws {
    let dynamic = try fixtureRoot(libraries: [library(path: "Demo.framework", variant: nil)])
    let simulatorOnly = try fixtureRoot(libraries: [
      library(path: "libdemo.a", variant: "simulator")
    ])
    defer {
      try? FileManager.default.removeItem(at: dynamic)
      try? FileManager.default.removeItem(at: simulatorOnly)
    }

    #expect(
      throws: BuildError.unsupportedBinaryTarget(
        "Demo", "'Demo.framework' is not a static archive (.a)")
    ) {
      try planner(root: dynamic, platform: .device).validateStaticXCFramework(
        name: "Demo", path: "Demo.xcframework")
    }
    #expect(throws: BuildError.unsupportedBinaryTarget("Demo", "it has no arm64 iOS library")) {
      try planner(root: simulatorOnly, platform: .device).validateStaticXCFramework(
        name: "Demo", path: "Demo.xcframework")
    }
    #expect(throws: BuildError.self) {
      try planner(root: simulatorOnly, platform: .device).validateStaticXCFramework(
        name: "Demo", path: "/tmp/artifacts/Demo.xcframework")
    }
    #expect(throws: BuildError.self) {
      try planner(root: simulatorOnly, platform: .device).validateStaticXCFramework(
        name: "Demo", path: "Missing.xcframework")
    }
  }

  @Test("links a static-library XCFramework into the app executable")
  func linksStaticLibrary() throws {
    guard let installation = XcodeLocator.detect() else {
      // Building the C archive and app needs Xcode's clang, libtool, and SDK.
      return
    }
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = container.appendingPathComponent("BinApp", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    try makeStaticXCFramework(at: root.appendingPathComponent("Demo.xcframework"), in: container)

    let app = root.appendingPathComponent("Sources/BinApp", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "BinApp",
        platforms: [.iOS("17.0")],
        products: [.library(name: "BinApp", targets: ["BinApp"])],
        targets: [
            .binaryTarget(name: "Demo", path: "Demo.xcframework"),
            .target(name: "BinApp", dependencies: ["Demo"]),
        ]
    )
    """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try """
    import Demo
    import SwiftUI

    @main
    struct BinAppApp: App {
        var body: some Scene {
            WindowGroup { Text("\\(demo_answer())") }
        }
    }
    """.write(to: app.appendingPathComponent("BinApp.swift"), atomically: true, encoding: .utf8)
    try emptyPlist.write(
      to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

    let plan = try Planner(
      projectRoot: root, config: config, swiftPath: installation.toolchainSwiftURL.path
    ).makePlan()
    // A static archive adds nothing to embed.
    #expect(plan.resources.isEmpty)

    let packer = Packer(
      projectRoot: root, plan: plan, config: config,
      swiftPath: installation.toolchainSwiftURL.path, sdkID: "stupid-app-ios",
      sdkInput: .xcodeInPlace(installation), buildConfiguration: .debug)
    defer { try? FileManager.default.removeItem(at: packer.builderCacheRoot) }
    let appURL = try packer.pack()
    let executable = appURL.appendingPathComponent(plan.product)
    #expect(try MachOInspector.inspect(at: executable).cpuArchitecture == "arm64")
    #expect(
      !FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Frameworks").path))

    let symbols = try ProcessRunner.run(
      executable: "/usr/bin/nm", arguments: ["-g", executable.path])
    #expect(symbols.stdout.contains("_demo_answer"))
  }

  // MARK: Fixtures

  private func planner(root: URL, platform: TargetPlatform) -> Planner {
    Planner(projectRoot: root, config: config, platform: platform)
  }

  private func library(path: String, variant: String?) -> [String: Any] {
    var library: [String: Any] = [
      "LibraryIdentifier": variant.map { "ios-arm64-\($0)" } ?? "ios-arm64",
      "LibraryPath": path,
      "SupportedArchitectures": ["arm64"],
      "SupportedPlatform": "ios",
    ]
    library["SupportedPlatformVariant"] = variant
    return library
  }

  /// A package root holding `Demo.xcframework/Info.plist` only; the planner reads nothing else.
  private func fixtureRoot(libraries: [[String: Any]]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let framework = root.appendingPathComponent("Demo.xcframework", isDirectory: true)
    try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
    let info: [String: Any] = [
      "AvailableLibraries": libraries,
      "CFBundlePackageType": "XFWK",
      "XCFrameworkFormatVersion": "1.0",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: framework.appendingPathComponent("Info.plist"))
    return root
  }

  /// Compiles a one-function C archive for the device and wraps it, with its header and module
  /// map, as an XCFramework.
  private func makeStaticXCFramework(at output: URL, in work: URL) throws {
    let headers = work.appendingPathComponent("headers", isDirectory: true)
    try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
    try "int demo_answer(void);\n".write(
      to: headers.appendingPathComponent("demo.h"), atomically: true, encoding: .utf8)
    try "module Demo {\n    header \"demo.h\"\n    export *\n}\n".write(
      to: headers.appendingPathComponent("module.modulemap"), atomically: true, encoding: .utf8)
    let source = work.appendingPathComponent("demo.c")
    try "int demo_answer(void) { return 42; }\n".write(
      to: source, atomically: true, encoding: .utf8)
    let object = work.appendingPathComponent("demo.o")
    let archive = work.appendingPathComponent("libdemo.a")

    for (tool, arguments) in [
      (
        "clang",
        [
          "-sdk", "iphoneos", "clang", "-target", "arm64-apple-ios17.0", "-c", source.path, "-o",
          object.path,
        ]
      ),
      ("libtool", ["libtool", "-static", "-o", archive.path, object.path]),
      (
        "xcodebuild",
        [
          "xcodebuild", "-create-xcframework", "-library", archive.path, "-headers", headers.path,
          "-output", output.path,
        ]
      ),
    ] {
      let result = try ProcessRunner.run(executable: "/usr/bin/xcrun", arguments: arguments)
      guard result.succeeded else {
        throw BuildError.processingFailed(tool, result.stderr)
      }
    }
  }

  private var emptyPlist: String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict></dict></plist>
    """
  }
}
