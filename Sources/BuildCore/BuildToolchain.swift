import Foundation
import ProjectCore
import SDKCore

/// The resolved host build toolchain and SDK input selected by the active host mode.
///
/// With a usable Xcode (Xcode SDK in place) the toolchain is Xcode's bundled `swift`
/// and builds target Xcode's iPhoneOS or iPhoneSimulator SDK in place; otherwise the
/// caller's host `swift` and the imported `stupid-app` artifact bundle are used (which
/// can only target the device because simulators cannot exist without Xcode). Commands
/// resolve this once and hand it to the planner and packer so the two modes share one
/// code path.
public struct BuildToolchain: Sendable {
  public var swiftPath: String
  public var sdkID: String
  public var sdkInput: SDKInput
  public var hostSDKVersion: @Sendable () throws -> String

  /// Resolves the toolchain for a detected host mode. `swiftPath` is the caller's
  /// requested compiler; with Xcode in place the default (`"swift"`) is replaced by
  /// Xcode's toolchain `swift` unless the caller explicitly overrode it. The simulator
  /// platform resolves its SDK version from the in-place Xcode installation and fails
  /// loudly when no Xcode is present.
  public static func resolve(
    swiftPath: String,
    sdkID: String,
    targetTriple: String,
    mode: HostSDKMode,
    platform: TargetPlatform = .device,
    sdkVersionOverride: String? = nil
  ) -> BuildToolchain {
    let resolvedSwift: String
    let sdkInput: SDKInput
    switch mode {
    case let .xcodeInPlace(installation):
      resolvedSwift =
        swiftPath == "swift" ? installation.toolchainSwiftURL.path : swiftPath
      sdkInput = .xcodeInPlace(installation)
    case .importedBundle:
      resolvedSwift = swiftPath
      sdkInput = .importedBundle(sdkID: sdkID)
    }

    let resolvedSDKID = sdkID
    let resolvedTriple = targetTriple
    let resolvedSwiftClosure = resolvedSwift
    let resolvedOverride = sdkVersionOverride
    let hostSDKVersion: @Sendable () throws -> String
    switch (mode, platform) {
    case (.xcodeInPlace(let installation), .simulator):
      let simulatorVersion = installation.iphoneSimulatorSDKVersion
      hostSDKVersion = { @Sendable in
        if let resolvedOverride {
          return try Self.validatedOverride(resolvedOverride)
        }
        guard let simulatorVersion else {
          throw BuildError.missingSimulatorSDK(installation.appURL.path)
        }
        return simulatorVersion
      }
    case (.importedBundle, .simulator):
      // Simulators cannot exist without Xcode; fail loudly before any build starts.
      hostSDKVersion = { @Sendable in
        throw BuildError.simulatorRequiresXcode
      }
    default:
      hostSDKVersion = { @Sendable in
        try SDKVersion.resolve(
          sdkID: resolvedSDKID,
          targetTriple: resolvedTriple,
          swiftPath: resolvedSwiftClosure,
          override: resolvedOverride
        )
      }
    }
    return BuildToolchain(
      swiftPath: resolvedSwift,
      sdkID: sdkID,
      sdkInput: sdkInput,
      hostSDKVersion: hostSDKVersion
    )
  }

  private static func validatedOverride(_ override: String) throws -> String {
    guard AppConfig.isValidVersion(override) else {
      throw ProjectError.invalidDeploymentTarget(override)
    }
    return override
  }
}
