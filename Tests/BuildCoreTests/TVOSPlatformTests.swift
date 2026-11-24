import Foundation
import ProjectCore
import Testing

@testable import BuildCore

/// tvOS target naming and the synthesized tvOS Info.plist keys.
struct TVOSPlatformTests {
  @Test("tvOS device and simulator map to the AppleTV SDKs, triples and linker platforms")
  func platformNames() {
    let device = TargetPlatform(os: .tvos, environment: .device)
    let simulator = TargetPlatform(os: .tvos, environment: .simulator)
    #expect(device.targetTriple == "arm64-apple-tvos")
    #expect(simulator.targetTriple == "arm64-apple-tvos-simulator")
    #expect(simulator.tripleWithVersion("26.0") == "arm64-apple-tvos26.0-simulator")
    #expect(device.linkerPlatformName == "tvos")
    #expect(simulator.linkerPlatformName == "tvos-simulator")
    #expect(device.sdkPlatformName == "appletvos")
    #expect(simulator.sdkPlatformName == "appletvsimulator")
    #expect(device.supportedPlatformsKey == "AppleTVOS")
    #expect(simulator.supportedPlatformsKey == "AppleTVSimulator")
    #expect(device.packageDescriptionPlatform == "tvOS")
  }

  @Test("iOS platforms keep their historical names")
  func iosNamesUnchanged() {
    #expect(TargetPlatform.device.targetTriple == "arm64-apple-ios")
    #expect(TargetPlatform.simulator.linkerPlatformName == "ios-simulator")
    #expect(TargetPlatform.device.sdkPlatformName == "iphoneos")
    #expect(TargetPlatform.simulator.supportedPlatformsKey == "iPhoneSimulator")
  }

  @Test("a tvOS app declares the Apple TV device family and no orientations")
  func tvosInfoPlist() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("planner-tvos-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict/></plist>
      """.utf8
    ).write(to: root.appendingPathComponent("Info.plist"))
    let platform = TargetPlatform(os: .tvos, environment: .device)
    let planner = Planner(
      projectRoot: root,
      config: AppConfig(
        version: 1, product: "Fixture", bundleID: "net.example.fixture",
        deploymentTarget: "26.0", infoPath: "Info.plist", platform: "tvos"),
      targetTriple: platform.targetTriple, platform: platform)
    let info = try planner.synthesizeInfoPlist(
      product: "Fixture", bundleID: "net.example.fixture", deploymentTarget: "26.0",
      platform: platform, isExtension: false, infoPath: "Info.plist",
      deviceFamily: .universal)
    #expect(info["UIDeviceFamily"] as? [Int] == [3])
    #expect(info["CFBundleSupportedPlatforms"] as? [String] == ["AppleTVOS"])
    #expect(info["UISupportedInterfaceOrientations"] == nil)
    #expect(info["UILaunchScreen"] == nil)
  }
}
