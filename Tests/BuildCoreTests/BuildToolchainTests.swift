import Foundation
import SDKCore
import Testing

@testable import BuildCore

/// Hermetic tests for the mode-aware build toolchain resolution shared by the build,
/// run, and release commands.
struct BuildToolchainTests {
  private let installation = XcodeInstallation(
    appURL: URL(fileURLWithPath: "/Applications/Xcode.app"),
    developerDirectory: URL(
      fileURLWithPath: "/Applications/Xcode.app/Contents/Developer"),
    iphoneOSSDKURL: URL(
      fileURLWithPath:
        "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
    ),
    iphoneSimulatorSDKURL: nil,
    toolchainSwiftURL: URL(
      fileURLWithPath:
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
    ),
    toolchainSwiftcURL: URL(
      fileURLWithPath:
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    ),
    toolchainBinDirectory: URL(
      fileURLWithPath:
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"),
    version: "26.3",
    build: "17C529",
    iphoneosSDKVersion: "26.2"
  )

  @Test("xcode in place substitutes Xcode's toolchain swift for the default path")
  func xcodeInPlaceDefaultSwift() {
    let toolchain = BuildToolchain.resolve(
      swiftPath: "swift",
      sdkID: "stupid-app-ios",
      targetTriple: "arm64-apple-ios",
      mode: .xcodeInPlace(installation)
    )
    #expect(toolchain.swiftPath == installation.toolchainSwiftURL.path)
    #expect(toolchain.sdkInput == .xcodeInPlace(installation))
    #expect((try? toolchain.hostSDKVersion()) == "26.2")
  }

  @Test("xcode in place honors an explicit swift path override")
  func xcodeInPlaceExplicitSwift() {
    let toolchain = BuildToolchain.resolve(
      swiftPath: "/custom/swift",
      sdkID: "stupid-app-ios",
      targetTriple: "arm64-apple-ios",
      mode: .xcodeInPlace(installation)
    )
    #expect(toolchain.swiftPath == "/custom/swift")
  }

  @Test("imported bundle keeps the host swift and bundle SDK input")
  func importedBundle() {
    let toolchain = BuildToolchain.resolve(
      swiftPath: "swift",
      sdkID: "my-sdk",
      targetTriple: "arm64-apple-ios",
      mode: .importedBundle
    )
    #expect(toolchain.swiftPath == "swift")
    #expect(toolchain.sdkInput == .importedBundle(sdkID: "my-sdk"))
  }

  @Test("the sdk-version override wins over the host mode")
  func sdkOverrideWins() {
    let toolchain = BuildToolchain.resolve(
      swiftPath: "swift",
      sdkID: "stupid-app-ios",
      targetTriple: "arm64-apple-ios",
      mode: .xcodeInPlace(installation),
      sdkVersionOverride: "17.5"
    )
    #expect((try? toolchain.hostSDKVersion()) == "17.5")
  }
}
