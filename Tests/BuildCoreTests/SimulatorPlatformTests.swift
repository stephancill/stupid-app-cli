import Foundation
import SDKCore
import Testing

@testable import BuildCore

/// Hermetic tests for the simulator platform mappings and the `simctl` output
/// parsers. No Xcode or running simulator is required.
struct SimulatorPlatformTests {
  @Test("platform mappings are distinct and correct")
  func platformMappings() {
    #expect(TargetPlatform.device.targetTriple == "arm64-apple-ios")
    #expect(TargetPlatform.simulator.targetTriple == "arm64-apple-ios-simulator")
    #expect(TargetPlatform.device.linkerPlatformName == "ios")
    #expect(TargetPlatform.simulator.linkerPlatformName == "ios-simulator")
    #expect(TargetPlatform.device.sdkPlatformName == "iphoneos")
    #expect(TargetPlatform.simulator.sdkPlatformName == "iphonesimulator")
    #expect(TargetPlatform.device.supportedPlatformsKey == "iPhoneOS")
    #expect(TargetPlatform.simulator.supportedPlatformsKey == "iPhoneSimulator")
  }

  @Test("simulator build-system keys use the simulator SDK identity")
  func simulatorBuildSystemKeys() {
    let metadata = BuildSystemMetadata(
      iphoneosSDKVersion: "26.1", xcodeVersion: "26.1.1", xcodeBuild: "17B100")
    var info: [String: Sendable] = [:]
    Packer.injectBuildSystemKeys(into: &info, metadata: metadata, platform: .simulator)

    #expect(info["DTPlatformName"] as? String == "iphonesimulator")
    #expect(info["DTPlatformVersion"] as? String == "26.1")
    #expect(info["DTSDKName"] as? String == "iphonesimulator26.1")
    #expect(info["DTXcode"] as? String == "2611")
    #expect(info["DTXcodeBuild"] as? String == "17B100")
    #expect(info["BuildMachineOSBuild"] == nil)
  }

  @Test("device build-system keys remain iphoneos by default")
  func deviceBuildSystemKeys() {
    let metadata = BuildSystemMetadata(
      iphoneosSDKVersion: "26.1", xcodeVersion: "26.1.1", xcodeBuild: "17B100")
    var info: [String: Sendable] = [:]
    Packer.injectBuildSystemKeys(into: &info, metadata: metadata)
    #expect(info["DTPlatformName"] as? String == "iphoneos")
    #expect(info["DTSDKName"] as? String == "iphoneos26.1")
  }

  @Test("simctl device JSON parses with runtime grouping")
  func simctlDevicesParse() throws {
    let output = """
      {
        "devices" : {
          "com.apple.CoreSimulator.SimRuntime.iOS-26-3" : [
            { "name" : "NoFeedSocial iOS 26.3", "udid" : "6552DF1D-95CE-48E3-801F-8F80F0AA8D29", "state" : "Booted" }
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-18-6" : [
            { "name" : "Old Phone", "udid" : "A1B2", "state" : "Shutdown" }
          ]
        }
      }
      """
    let devices = try Simctl.parseDevices(output)
    #expect(devices.count == 2)
    #expect(devices[0].runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-18-6")
    #expect(devices[1].name == "NoFeedSocial iOS 26.3")
    #expect(devices[1].state == "Booted")
    #expect(devices[1].udid == "6552DF1D-95CE-48E3-801F-8F80F0AA8D29")
  }

  @Test("simctl runtime JSON parses in name order")
  func simctlRuntimesParse() throws {
    let output = """
      {
        "runtimes" : [
          { "name" : "iOS 26.1", "identifier" : "com.apple.CoreSimulator.SimRuntime.iOS-26-1" },
          { "name" : "iOS 18.6", "identifier" : "com.apple.CoreSimulator.SimRuntime.iOS-18-6" }
        ]
      }
      """
    let runtimes = try Simctl.parseRuntimes(output)
    #expect(runtimes.map(\.name) == ["iOS 18.6", "iOS 26.1"])
    #expect(runtimes[0].identifier == "com.apple.CoreSimulator.SimRuntime.iOS-18-6")
  }

  @Test("malformed simctl output fails loudly")
  func simctlUnparseable() {
    #expect(throws: Simctl.Error.self) {
      _ = try Simctl.parseDevices("not json")
    }
  }

  private let installation = XcodeInstallation(
    appURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
    developerDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
    iphoneOSSDKURL: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"),
    iphoneSimulatorSDKURL: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"),
    toolchainSwiftURL: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"),
    toolchainSwiftcURL: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"),
    toolchainBinDirectory: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"),
    version: "26.1.1",
    build: "17B100",
    iphoneosSDKVersion: "26.1",
    iphoneSimulatorSDKVersion: "26.1"
  )

  @Test("simulator toolchain resolves the in-place simulator SDK version")
  func simulatorToolchain() throws {
    let toolchain = BuildToolchain.resolve(
      swiftPath: "swift",
      sdkID: "stupid-app-ios",
      targetTriple: TargetPlatform.simulator.targetTriple,
      mode: .xcodeInPlace(installation),
      platform: .simulator
    )
    #expect(toolchain.swiftPath == installation.toolchainSwiftURL.path)
    #expect(try toolchain.hostSDKVersion() == "26.1")
  }

  @Test("simulator toolchain on an importedBundle host fails loudly")
  func simulatorRequiresXcode() {
    let toolchain = BuildToolchain.resolve(
      swiftPath: "swift",
      sdkID: "stupid-app-ios",
      targetTriple: TargetPlatform.simulator.targetTriple,
      mode: .importedBundle,
      platform: .simulator
    )
    #expect {
      try toolchain.hostSDKVersion()
    } throws: { error in
      error as? BuildError == .simulatorRequiresXcode
    }
  }
}