import Foundation
import SDKCore
import Testing

@testable import BuildCore

/// Tests for Info.plist build-system key injection that App Store Connect requires.
struct BuildSystemKeyTests {
  @Test("injects platform and Xcode provenance keys")
  func injectsBuildSystemKeys() {
    var info: [String: Sendable] = ["CFBundleIdentifier": "net.example.app"]
    Packer.injectBuildSystemKeys(
      into: &info,
      metadata: BuildSystemMetadata(
        iphoneosSDKVersion: "26.1",
        xcodeVersion: "26.1.1",
        xcodeBuild: "17B100"
      ))

    #expect(info["DTPlatformName"] as? String == "iphoneos")
    #expect(info["DTPlatformVersion"] as? String == "26.1")
    #expect(info["DTSDKName"] as? String == "iphoneos26.1")
    #expect(info["DTXcode"] as? String == "2611")
    #expect(info["DTXcodeBuild"] as? String == "17B100")
    #expect(info["DTCompiler"] as? String == "com.apple.compilers.llvm.clang.1_0")
    // The build machine is macOS-specific; it must never be invented on Linux.
    #expect(info["BuildMachineOSBuild"] == nil)
  }

  @Test("injects the same keys from in-place Xcode metadata")
  func injectsFromInPlaceMetadata() {
    let metadata = BuildSystemMetadata(
      iphoneosSDKVersion: "26.1",
      xcodeVersion: "26.1.1",
      xcodeBuild: "17B100"
    )
    var info: [String: Sendable] = ["CFBundleIdentifier": "net.example.app"]
    Packer.injectBuildSystemKeys(into: &info, metadata: metadata)

    #expect(info["DTPlatformName"] as? String == "iphoneos")
    #expect(info["DTPlatformVersion"] as? String == "26.1")
    #expect(info["DTSDKName"] as? String == "iphoneos26.1")
    #expect(info["DTXcode"] as? String == "2611")
    #expect(info["DTXcodeBuild"] as? String == "17B100")
    #expect(info["DTCompiler"] as? String == "com.apple.compilers.llvm.clang.1_0")
    #expect(info["BuildMachineOSBuild"] == nil)
  }

  @Test("numeric Xcode version conversion")
  func numericXcodeVersion() {
    #expect(Packer.numericXcodeVersion("26.1.1") == "2611")
    #expect(Packer.numericXcodeVersion("26.0") == "260")
    #expect(Packer.numericXcodeVersion("15.0.0") == "1500")
    #expect(Packer.numericXcodeVersion("26.1.1.2") == "2611")
  }

  @Test("injects asset-catalog icon names into phone and iPad primary icons")
  func injectsIconNames() {
    var info: [String: Sendable] = [:]
    Packer.injectIconKeys(into: &info)

    let phoneIcons = info["CFBundleIcons"] as? [String: [String: any Sendable]]
    let padIcons = info["CFBundleIcons~ipad"] as? [String: [String: any Sendable]]
    #expect(phoneIcons?["CFBundlePrimaryIcon"]?["CFBundleIconName"] as? String == "AppIcon")
    #expect(padIcons?["CFBundlePrimaryIcon"]?["CFBundleIconName"] as? String == "AppIcon")
  }
}
