import Foundation
import ProjectCore
import SDKCore
import Testing

@testable import BuildCore

/// End-to-end Gate M0 proof: when a usable Xcode with an iPhoneOS SDK is present, the
/// planner and packer build an unsigned iOS `.app` in place through Xcode's toolchain
/// without registering or importing any artifact bundle.
struct PackerModeATests {
  @Test("builds an ARM64 iOS Mach-O from Xcode's SDK in place when Xcode is present")
  func xcodeInPlaceBuild() throws {
    guard let installation = XcodeLocator.detect() else {
      // Not a macOS host with Xcode (e.g. Linux CI): nothing to prove here.
      return
    }

    let root = try testProjectRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    let config = AppConfig(
      version: 1,
      product: "ModeApp",
      bundleID: "net.example.mode-app",
      deploymentTarget: "17.0",
      infoPath: "Info.plist"
    )

    let planner = Planner(
      projectRoot: root, config: config, swiftPath: installation.toolchainSwiftURL.path)
    let plan = try planner.makePlan()

    let packer = Packer(
      projectRoot: root,
      plan: plan,
      config: config,
      swiftPath: installation.toolchainSwiftURL.path,
      sdkID: "stupid-app-ios",
      sdkInput: .xcodeInPlace(installation),
      buildConfiguration: .debug
    )
    defer { try? FileManager.default.removeItem(at: packer.builderCacheRoot) }

    let appURL = try packer.pack()
    #expect(
      FileManager.default.fileExists(atPath: appURL.appendingPathComponent(plan.product).path))
    let scratch = packer.buildScratchDirectory(for: plan.product)
    #expect(FileManager.default.fileExists(atPath: scratch.path))
    let marker = scratch.appendingPathComponent("reuse-marker")
    try Data().write(to: marker)

    _ = try packer.pack()
    #expect(FileManager.default.fileExists(atPath: marker.path))

    try FileManager.default.removeItem(
      at: root.appendingPathComponent("Sources/ModeApp/RemovedView.swift"))
    let updatedPlan = try Planner(
      projectRoot: root, config: config, swiftPath: installation.toolchainSwiftURL.path
    ).makePlan()
    #expect(updatedPlan.packageLayoutHash != plan.packageLayoutHash)
    let updatedPacker = Packer(
      projectRoot: root,
      plan: updatedPlan,
      config: config,
      swiftPath: installation.toolchainSwiftURL.path,
      sdkID: "stupid-app-ios",
      sdkInput: .xcodeInPlace(installation),
      buildConfiguration: .debug
    )
    _ = try updatedPacker.pack()
    #expect(!FileManager.default.fileExists(atPath: marker.path))

    let info = try MachOInspector.inspect(at: appURL.appendingPathComponent(plan.product))
    #expect(info.isMachO)
    #expect(info.cpuArchitecture == "arm64")
    #expect(info.platform == "ios")
    // The real SDK version (not the deployment target) reaches LC_BUILD_VERSION.
    // MachOInspector normalizes to three components (26.1.0); the source value is
    // the two-component SDK version.
    #expect(info.sdkVersion?.hasPrefix(installation.iphoneosSDKVersion) == true)

    // Build-system keys come from Xcode in place, with no invented BuildMachineOSBuild.
    let mergedInfo =
      try PropertyListSerialization.propertyList(
        from: Data(contentsOf: appURL.appendingPathComponent("Info.plist")),
        format: nil) as? [String: Any]
    #expect(mergedInfo?["DTPlatformName"] as? String == "iphoneos")
    #expect(mergedInfo?["DTPlatformVersion"] as? String == installation.iphoneosSDKVersion)
    #expect(mergedInfo?["DTSDKName"] as? String == "iphoneos\(installation.iphoneosSDKVersion)")
    #expect(mergedInfo?["DTXcodeBuild"] as? String == installation.build)
    #expect(mergedInfo?["BuildMachineOSBuild"] == nil)
  }

  @Test("builds an ARM64 simulator Mach-O from Xcode's iPhoneSimulator SDK in place")
  func xcodeInPlaceSimulatorBuild() throws {
    guard
      let installation = XcodeLocator.detect(),
      installation.iphoneSimulatorSDKURL != nil,
      installation.iphoneSimulatorSDKVersion != nil
    else {
      // Not a macOS host with Xcode and a simulator SDK: nothing to prove here.
      return
    }

    let root = try testProjectRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    let config = AppConfig(
      version: 1,
      product: "ModeApp",
      bundleID: "net.example.mode-app",
      deploymentTarget: "17.0",
      infoPath: "Info.plist"
    )

    let planner = Planner(
      projectRoot: root,
      config: config,
      swiftPath: installation.toolchainSwiftURL.path,
      targetTriple: TargetPlatform.simulator.targetTriple,
      platform: .simulator
    )
    let plan = try planner.makePlan()
    #expect(plan.platform == .simulator)
    #expect(plan.infoPlist["CFBundleSupportedPlatforms"] as? [String] == ["iPhoneSimulator"])

    let packer = Packer(
      projectRoot: root,
      plan: plan,
      config: config,
      swiftPath: installation.toolchainSwiftURL.path,
      targetTriple: TargetPlatform.simulator.targetTriple,
      sdkID: "stupid-app-ios",
      sdkInput: .xcodeInPlace(installation),
      buildConfiguration: .debug
    )
    defer { try? FileManager.default.removeItem(at: packer.builderCacheRoot) }
    let appURL = try packer.pack()

    let info = try MachOInspector.inspect(at: appURL.appendingPathComponent(plan.product))
    #expect(info.isMachO)
    #expect(info.cpuArchitecture == "arm64")
    #expect(info.platform == "ios-simulator")
    #expect(info.sdkVersion?.hasPrefix(installation.iphoneSimulatorSDKVersion!) == true)

    let mergedInfo =
      try PropertyListSerialization.propertyList(
        from: Data(contentsOf: appURL.appendingPathComponent("Info.plist")),
        format: nil) as? [String: Any]
    #expect(mergedInfo?["DTPlatformName"] as? String == "iphonesimulator")
    #expect(
      mergedInfo?["DTSDKName"] as? String
        == "iphonesimulator\(installation.iphoneSimulatorSDKVersion!)")
  }

  @Test("copies a library target's resources under SwiftPM's <Package>_<Target>.bundle name")
  func resourceBundleUsesSwiftPMName() throws {
    guard let installation = XcodeLocator.detect() else { return }

    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = container.appendingPathComponent("ResPkg", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let core = root.appendingPathComponent("Sources/ResCore/Resources", isDirectory: true)
    let app = root.appendingPathComponent("Sources/ResApp", isDirectory: true)
    try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    // The package name differs from both target names so the test pins which one
    // SwiftPM uses as the bundle prefix.
    try """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "ResPkg",
        platforms: [.iOS("17.0")],
        products: [.library(name: "ResApp", targets: ["ResApp"])],
        targets: [
            .target(name: "ResCore", resources: [.copy("Resources/schema.txt")]),
            .target(name: "ResApp", dependencies: ["ResCore"]),
        ]
    )
    """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try "schema".write(
      to: core.appendingPathComponent("schema.txt"), atomically: true, encoding: .utf8)
    try """
    import Foundation
    public let schemaURL = Bundle.module.url(forResource: "schema", withExtension: "txt")
    """.write(
      to: core.deletingLastPathComponent().appendingPathComponent("Core.swift"),
      atomically: true, encoding: .utf8)
    try """
    import ResCore
    import SwiftUI

    @main
    struct ResAppApp: App {
        var body: some Scene {
            WindowGroup { Text(schemaURL?.lastPathComponent ?? "missing") }
        }
    }
    """.write(to: app.appendingPathComponent("ResApp.swift"), atomically: true, encoding: .utf8)
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict></dict></plist>
    """.write(to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

    let config = AppConfig(
      version: 1, product: "ResApp", bundleID: "net.example.res-app",
      deploymentTarget: "17.0", infoPath: "Info.plist")
    let plan = try Planner(
      projectRoot: root, config: config, swiftPath: installation.toolchainSwiftURL.path
    ).makePlan()
    #expect(plan.resources == [.bundle(package: "ResPkg", target: "ResCore")])

    let packer = Packer(
      projectRoot: root, plan: plan, config: config,
      swiftPath: installation.toolchainSwiftURL.path, sdkID: "stupid-app-ios",
      sdkInput: .xcodeInPlace(installation), buildConfiguration: .debug)
    defer { try? FileManager.default.removeItem(at: packer.builderCacheRoot) }
    let appURL = try packer.pack()
    #expect(
      FileManager.default.fileExists(
        atPath: appURL.appendingPathComponent("ResPkg_ResCore.bundle/schema.txt").path))
  }

  @Test("fails loudly when a target declares resources but its bundle is missing")
  func missingResourceBundleThrows() throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let binDir = container.appendingPathComponent("bin", isDirectory: true)
    let appDir = container.appendingPathComponent("App.app", isDirectory: true)
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
    // A bundle under the bare target name is not what Bundle.module looks for.
    try FileManager.default.createDirectory(
      at: binDir.appendingPathComponent("Core.bundle"), withIntermediateDirectories: true)

    #expect(throws: BuildError.self) {
      try Packer.copyResourceBundle(
        package: "Pkg", target: "Core", from: binDir, into: appDir, phase: "app assembly")
    }
  }

  private func testProjectRoot() throws -> URL {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = container.appendingPathComponent("ModeApp", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true)

    try """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "ModeApp",
        platforms: [.iOS("17.0")],
        products: [.library(name: "ModeApp", targets: ["ModeApp"])],
        targets: [
            .target(name: "ModeApp")
        ]
    )
    """.write(
      to: root.appendingPathComponent("Package.swift"),
      atomically: true, encoding: .utf8)

    let sources = root.appendingPathComponent("Sources/ModeApp", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try """
    import SwiftUI

    @main
    struct ModeAppApp: App {
        var body: some Scene {
            WindowGroup { Text("mode-a") }
        }
    }
    """.write(
      to: sources.appendingPathComponent("ModeApp.swift"),
      atomically: true, encoding: .utf8)

    try """
    import SwiftUI

    struct RemovedView: View {
        var body: some View { Text("removed") }
    }
    """.write(
      to: sources.appendingPathComponent("RemovedView.swift"),
      atomically: true, encoding: .utf8)

    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict></dict></plist>
    """.write(
      to: root.appendingPathComponent("Info.plist"),
      atomically: true, encoding: .utf8)
    return root
  }
}
