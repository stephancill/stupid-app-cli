import Foundation

/// The iOS target platform a build addresses. `device` produces physical-device
/// binaries (and later distribution artifacts); `simulator` produces simulator
/// binaries that only run through `simctl` in an Xcode-present host.
public enum TargetPlatform: String, Sendable, Equatable {
  case device
  case simulator

  /// SwiftPM target triple this platform builds for. Intel simulator triples are
  /// deferred with the Intel host matrix.
  public var targetTriple: String {
    switch self {
    case .device:
      return "arm64-apple-ios"
    case .simulator:
      return "arm64-apple-ios-simulator"
    }
  }

  /// Linker `-platform_version` platform identifier.
  public var linkerPlatformName: String {
    switch self {
    case .device:
      return "ios"
    case .simulator:
      return "ios-simulator"
    }
  }

  /// Xcode platform directory and `DTPlatformName` identifier.
  public var sdkPlatformName: String {
    switch self {
    case .device:
      return "iphoneos"
    case .simulator:
      return "iphonesimulator"
    }
  }

  /// The `CFBundleSupportedPlatforms` value stored in the app's Info.plist.
  public var supportedPlatformsKey: String {
    switch self {
    case .device:
      return "iPhoneOS"
    case .simulator:
      return "iPhoneSimulator"
    }
  }
}