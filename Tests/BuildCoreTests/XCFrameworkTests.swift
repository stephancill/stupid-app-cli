import Foundation
import ProjectCore
import SDKCore
import Testing

@testable import BuildCore

/// Binary targets are XCFrameworks with an arm64 library for the build's platform: static
/// archives link into the executable, dynamic frameworks are embedded under `Frameworks/`. The
/// planner reads a local XCFramework's Info.plist; a remote one is resolved after the build.
struct XCFrameworkTests {
  private let config = AppConfig(
    version: 1, product: "BinApp", bundleID: "net.example.bin-app",
    deploymentTarget: "17.0", infoPath: "Info.plist")

  @Test("a static-library XCFramework links in and embeds nothing")
  func acceptsStaticLibraries() throws {
    let root = try fixtureRoot(libraries: [
      library(path: "libdemo.a", variant: nil),
      library(path: "libdemo.a", variant: "simulator"),
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    for platform in [TargetPlatform.device, .simulator] {
      #expect(
        try planner(root: root, platform: platform).binaryTargetResource(
          name: "Demo", path: "Demo.xcframework", packageIdentity: "binapp") == nil)
    }
  }

  @Test("a dynamic-framework XCFramework, local or remote, becomes an embedded framework")
  func plansDynamicFrameworks() throws {
    let root = try fixtureRoot(libraries: [library(path: "Demo.framework", variant: nil)])
    defer { try? FileManager.default.removeItem(at: root) }
    let planner = planner(root: root, platform: .device)

    #expect(
      try planner.binaryTargetResource(
        name: "Demo", path: "Demo.xcframework", packageIdentity: "binapp")
        == .framework(
          target: "Demo",
          location: .local(root.appendingPathComponent("Demo.xcframework", isDirectory: true))))
    #expect(
      try planner.binaryTargetResource(
        name: "Remote", path: "remote/archive/Remote.xcframework.zip", packageIdentity: "remote-spm")
        == .framework(target: "Remote", location: .remote(packageIdentity: "remote-spm")))
  }

  @Test("rejects a missing platform slice, mixed kinds, artifact bundles, and absolute paths")
  func rejectsUnsupportedBinaries() throws {
    let simulatorOnly = try fixtureRoot(libraries: [
      library(path: "libdemo.a", variant: "simulator")
    ])
    let mixed = try fixtureRoot(libraries: [
      library(path: "libdemo.a", variant: nil),
      library(path: "Demo.framework", variant: "simulator"),
    ])
    defer {
      try? FileManager.default.removeItem(at: simulatorOnly)
      try? FileManager.default.removeItem(at: mixed)
    }

    #expect(throws: BuildError.unsupportedBinaryTarget("Demo", "it has no arm64 iOS library")) {
      try planner(root: simulatorOnly, platform: .device).binaryTargetResource(
        name: "Demo", path: "Demo.xcframework", packageIdentity: "binapp")
    }
    #expect(
      throws: BuildError.unsupportedBinaryTarget(
        "Demo", "it mixes static archives and frameworks across platforms")
    ) {
      try planner(root: mixed, platform: .device).binaryTargetResource(
        name: "Demo", path: "Demo.xcframework", packageIdentity: "binapp")
    }
    for path in [
      "/tmp/artifacts/Demo.xcframework", "Missing.xcframework",
      "remote/archive/Demo.artifactbundle.zip",
    ] {
      #expect(throws: BuildError.self) {
        try planner(root: simulatorOnly, platform: .device).binaryTargetResource(
          name: "Demo", path: path, packageIdentity: "binapp")
      }
    }
  }

  @Test("embeds a framework without build-only content and with an arm64-only executable")
  func embedsFramework() throws {
    let root = try fixtureRoot(libraries: [
      library(path: "Demo.framework", variant: "simulator", identifier: "ios-arm64_x86_64-simulator")
    ])
    let bundle = FileManager.default.temporaryDirectory
      .appendingPathComponent("embed-\(UUID().uuidString).app", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: bundle)
    }
    let xcframework = root.appendingPathComponent("Demo.xcframework", isDirectory: true)
    let source = xcframework.appendingPathComponent(
      "ios-arm64_x86_64-simulator/Demo.framework", isDirectory: true)
    for directory in ["Headers", "Modules", "_CodeSignature", "Resources"] {
      try FileManager.default.createDirectory(
        at: source.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    try Data("header".utf8).write(to: source.appendingPathComponent("Headers/Demo.h"))
    try Data("asset".utf8).write(to: source.appendingPathComponent("Resources/asset.txt"))
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleExecutable": "Demo", "CFBundleIdentifier": "net.example.demo"],
      format: .xml, options: 0
    ).write(to: source.appendingPathComponent("Info.plist"))
    let arm64 = thinMachO(cpuType: 0x0100_000C, fileType: 6)
    try universal([thinMachO(cpuType: 0x0100_0007, fileType: 6), arm64])
      .write(to: source.appendingPathComponent("Demo"))
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

    try Packer.embedFramework(
      target: "Demo", location: .local(xcframework), scratch: root, platform: .simulator,
      into: bundle)

    let embedded = bundle.appendingPathComponent("Frameworks/Demo.framework", isDirectory: true)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: embedded.path).sorted()
        == ["Demo", "Info.plist", "Resources"])
    #expect(try Data(contentsOf: embedded.appendingPathComponent("Demo")) == arm64)
    #expect(FileManager.default.isExecutableFile(atPath: embedded.appendingPathComponent("Demo").path))

    // A second binary target shipping the same framework name is refused.
    #expect(throws: BuildError.self) {
      try Packer.embedFramework(
        target: "Other", location: .local(xcframework), scratch: root, platform: .simulator,
        into: bundle)
    }
  }

  @Test("thins universal Mach-O to arm64 and rejects one without an arm64 slice")
  func thinsUniversalMachO() throws {
    let arm64 = thinMachO(cpuType: 0x0100_000C, fileType: 6)
    let x86 = thinMachO(cpuType: 0x0100_0007, fileType: 6)
    #expect(try MachOThinner.arm64(universal([x86, arm64]), name: "Demo") == arm64)
    #expect(try MachOThinner.arm64(arm64, name: "Demo") == arm64)
    #expect(throws: MachOThinner.Error.noARM64Slice("Demo")) {
      try MachOThinner.arm64(universal([x86]), name: "Demo")
    }
    #expect(throws: MachOThinner.Error.noARM64Slice("Demo")) {
      try MachOThinner.arm64(x86, name: "Demo")
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

  private func library(path: String, variant: String?, identifier: String? = nil) -> [String: Any] {
    var library: [String: Any] = [
      "LibraryIdentifier": identifier ?? variant.map { "ios-arm64-\($0)" } ?? "ios-arm64",
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

  /// A minimal 64-bit Mach-O header; the thinner and embedder read nothing past it.
  private func thinMachO(cpuType: UInt32, fileType: UInt32) -> Data {
    var data = Data()
    for value in [0xFEED_FACF, cpuType, 0, fileType, 0, 0, 0, 0] as [UInt32] {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    return data + Data(repeating: UInt8(truncatingIfNeeded: cpuType), count: 32)
  }

  /// A universal binary holding `slices`, each 16-byte aligned after the fat header.
  private func universal(_ slices: [Data]) -> Data {
    func be32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    var header = be32(0xCAFE_BABE) + be32(UInt32(slices.count))
    var body = Data()
    let start = 8 + slices.count * 20
    for slice in slices {
      let offset = start + body.count
      let cpuType = slice.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
      }
      header += be32(cpuType) + be32(0) + be32(UInt32(offset)) + be32(UInt32(slice.count)) + be32(4)
      body += slice
    }
    return header + body
  }
}
