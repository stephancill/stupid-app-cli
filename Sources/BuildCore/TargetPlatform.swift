import Foundation
import ProjectCore
import SDKCore

/// The target a build addresses: an operating system (`ios` or `tvos`) and an
/// environment. `device` produces physical-device binaries (and later distribution
/// artifacts); `simulator` produces simulator binaries that only run through `simctl` in
/// an Xcode-present host (or x86Sim on Linux, for iOS).
public struct TargetPlatform: Sendable, Equatable, Hashable {
  public enum Environment: String, Sendable, Equatable, Hashable {
    case device
    case simulator
  }

  public var os: AppleOS
  public var environment: Environment

  public init(os: AppleOS, environment: Environment) {
    self.os = os
    self.environment = environment
  }

  public static let device = TargetPlatform(os: .ios, environment: .device)
  public static let simulator = TargetPlatform(os: .ios, environment: .simulator)

  public var isSimulator: Bool { environment == .simulator }

  /// The target-triple OS component without architecture or environment.
  public var tripleOS: String {
    switch os {
    case .ios: return "ios"
    case .tvos: return "tvos"
    }
  }

  /// SwiftPM target triple this platform builds for. Intel simulator triples are
  /// deferred with the Intel host matrix.
  public var targetTriple: String {
    tripleWithVersion(nil)
  }

  /// The target triple with an optional OS version (`arm64-apple-tvos17.0-simulator`).
  public func tripleWithVersion(_ version: String?) -> String {
    "arm64-apple-\(tripleOS)\(version ?? "")\(isSimulator ? "-simulator" : "")"
  }

  /// Linker `-platform_version` platform identifier.
  public var linkerPlatformName: String {
    "\(tripleOS)\(isSimulator ? "-simulator" : "")"
  }

  /// Xcode platform directory and `DTPlatformName` identifier.
  public var sdkPlatformName: String {
    switch (os, environment) {
    case (.ios, .device): return "iphoneos"
    case (.ios, .simulator): return "iphonesimulator"
    case (.tvos, .device): return "appletvos"
    case (.tvos, .simulator): return "appletvsimulator"
    }
  }

  /// The Xcode `Platforms/<name>.platform` directory name, also the
  /// `CFBundleSupportedPlatforms` value stored in the app's Info.plist.
  public var supportedPlatformsKey: String {
    switch (os, environment) {
    case (.ios, .device): return "iPhoneOS"
    case (.ios, .simulator): return "iPhoneSimulator"
    case (.tvos, .device): return "AppleTVOS"
    case (.tvos, .simulator): return "AppleTVSimulator"
    }
  }

  /// The `PackageDescription` platform constructor for the synthetic builder manifest.
  public var packageDescriptionPlatform: String {
    switch os {
    case .ios: return "iOS"
    case .tvos: return "tvOS"
    }
  }
}

extension XcodeInstallation {
  /// The in-place SDK for a target platform, failing loudly when this Xcode lacks it.
  public func sdk(for platform: TargetPlatform) throws -> PlatformSDK {
    if platform == .device {
      return PlatformSDK(url: iphoneOSSDKURL, version: iphoneosSDKVersion, build: iphoneosSDKBuild)
    }
    if platform == .simulator {
      guard let url = iphoneSimulatorSDKURL, let version = iphoneSimulatorSDKVersion else {
        throw BuildError.missingSimulatorSDK(appURL.path)
      }
      return PlatformSDK(url: url, version: version, build: iphoneSimulatorSDKBuild)
    }
    guard let sdk = platformSDK(platform.supportedPlatformsKey) else {
      throw BuildError.missingPlatformSDK(app: appURL.path, platform: platform.supportedPlatformsKey)
    }
    return sdk
  }
}
