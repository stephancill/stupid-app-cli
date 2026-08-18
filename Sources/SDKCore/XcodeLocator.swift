import Foundation

/// An Xcode installation usable as an in-place (Xcode-present) build input: an
/// iPhoneOS SDK, the Xcode toolchain's `swift`, and Xcode's own linker tooling
/// resolved **in place** without copying any SDK content.
public struct XcodeInstallation: Sendable, Equatable {
  public var appURL: URL
  public var developerDirectory: URL
  public var iphoneOSSDKURL: URL
  public var iphoneSimulatorSDKURL: URL?
  public var toolchainSwiftURL: URL
  public var toolchainSwiftcURL: URL
  public var toolchainBinDirectory: URL
  public var version: String
  public var build: String
  public var iphoneosSDKVersion: String
  public var iphoneSimulatorSDKVersion: String?

  public init(
    appURL: URL,
    developerDirectory: URL,
    iphoneOSSDKURL: URL,
    iphoneSimulatorSDKURL: URL?,
    toolchainSwiftURL: URL,
    toolchainSwiftcURL: URL,
    toolchainBinDirectory: URL,
    version: String,
    build: String,
    iphoneosSDKVersion: String,
    iphoneSimulatorSDKVersion: String? = nil
  ) {
    self.appURL = appURL
    self.developerDirectory = developerDirectory
    self.iphoneOSSDKURL = iphoneOSSDKURL
    self.iphoneSimulatorSDKURL = iphoneSimulatorSDKURL
    self.toolchainSwiftURL = toolchainSwiftURL
    self.toolchainSwiftcURL = toolchainSwiftcURL
    self.toolchainBinDirectory = toolchainBinDirectory
    self.version = version
    self.build = build
    self.iphoneosSDKVersion = iphoneosSDKVersion
    self.iphoneSimulatorSDKVersion = iphoneSimulatorSDKVersion
  }
}

/// Detects a usable Xcode installation for in-place (Xcode-present) builds.
///
/// The selected developer directory is resolved the same way `xcode-select` does,
/// without depending on `xcrun`:
///
/// 1. The `DEVELOPER_DIR` environment variable.
/// 2. The persisted selection symlink at `/var/db/xcode_select_link` (modern macOS).
/// 3. The persisted selection file at `/usr/share/xcode-select/xcode_dir_path`.
/// 4. The default `/Applications/Xcode.app`, then any `Xcode*.app` under
///    `/Applications` chosen by the highest Xcode version.
///
/// Command Line Tools is deliberately not considered Xcode: it has no iPhoneOS SDK.
public enum XcodeLocator {
  public struct Candidates: Sendable {
    public var environmentDeveloperDir: String?
    public var selectionSymlink: URL
    public var selectionFile: URL
    public var applicationDirectory: URL

    public init(
      environmentDeveloperDir: String? = nil,
      selectionSymlink: URL = URL(fileURLWithPath: "/var/db/xcode_select_link"),
      selectionFile: URL = URL(fileURLWithPath: "/usr/share/xcode-select/xcode_dir_path"),
      applicationDirectory: URL = URL(fileURLWithPath: "/Applications")
    ) {
      self.environmentDeveloperDir = environmentDeveloperDir
      self.selectionSymlink = selectionSymlink
      self.selectionFile = selectionFile
      self.applicationDirectory = applicationDirectory
    }
  }

  /// Resolves the active developer directory (`.../Contents/Developer`) through the
  /// same candidate order `xcode-select` uses. Returns nil when no candidate yields a
  /// directory that contains an iPhoneOS SDK.
  public static func resolvedDeveloperDirectory(
    candidates: Candidates? = nil
  ) -> URL? {
    let candidates = candidates ?? defaultCandidates()
    let environmentDir = normalizedDeveloperDirectory(
      path: candidates.environmentDeveloperDir)
    if let environmentDir, hasIPhoneOSSDK(at: environmentDir) {
      return environmentDir
    }

    if let symlinkTarget = symlinkTarget(of: candidates.selectionSymlink),
      hasIPhoneOSSDK(at: symlinkTarget)
    {
      return symlinkTarget
    }

    if let filePath = fileContents(of: candidates.selectionFile),
      let dir = normalizedDeveloperDirectory(path: filePath),
      hasIPhoneOSSDK(at: dir)
    {
      return dir
    }

    for defaultApp in defaultApps(in: candidates.applicationDirectory) {
      if hasIPhoneOSSDK(at: defaultApp) {
        return defaultApp
      }
    }
    return nil
  }

  /// Builds a validated installation description from a resolved developer
  /// directory, or nil when required resources are missing.
  public static func installation(
    developerDirectory: URL
  ) -> XcodeInstallation? {
    let devDir = developerDirectory.standardizedFileURL
    guard
      let sdk = sdkURL(in: devDir, platform: "iPhoneOS"),
      let sdkVersion = sdkVersion(at: sdk)
    else {
      return nil
    }

    let appURL = appURL(forDeveloperDirectory: devDir)
    let toolchainRoot =
      devDir.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain", isDirectory: true)
    let toolchainBin = toolchainRoot.appendingPathComponent("usr/bin", isDirectory: true)
    let swift = toolchainBin.appendingPathComponent("swift")
    let swiftc = toolchainBin.appendingPathComponent("swiftc")
    guard FileManager.default.isExecutableFile(atPath: swift.path),
      FileManager.default.isExecutableFile(atPath: swiftc.path)
    else {
      return nil
    }

    let (version, build) = xcodeVersion(appURL: appURL)
    let simulatorSDKURL = sdkURL(in: devDir, platform: "iPhoneSimulator")
    return XcodeInstallation(
      appURL: appURL,
      developerDirectory: devDir,
      iphoneOSSDKURL: sdk,
      iphoneSimulatorSDKURL: simulatorSDKURL,
      toolchainSwiftURL: swift,
      toolchainSwiftcURL: swiftc,
      toolchainBinDirectory: toolchainBin,
      version: version,
      build: build,
      iphoneosSDKVersion: sdkVersion,
      iphoneSimulatorSDKVersion: simulatorSDKURL.flatMap(sdkVersion(at:))
    )
  }

  /// Detects a usable Xcode installation, or nil when none is present.
  public static func detect(candidates: Candidates? = nil) -> XcodeInstallation? {
    guard let devDir = resolvedDeveloperDirectory(candidates: candidates) else {
      return nil
    }
    return installation(developerDirectory: devDir)
  }

  // MARK: - Resolution helpers

  private static func defaultCandidates() -> Candidates {
    Candidates(
      environmentDeveloperDir: ProcessInfo.processInfo.environment["DEVELOPER_DIR"])
  }

  /// Accepts either `.../Xcode.app` or `.../Xcode.app/Contents/Developer` and
  /// normalizes to the developer directory.
  private static func normalizedDeveloperDirectory(path: String?) -> URL? {
    guard let path, !path.isEmpty else { return nil }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    if url.lastPathComponent == "Developer", url.pathExtension.isEmpty {
      return url
    }
    return appURL(forDeveloperDirectory: url).appendingPathComponent(
      "Contents/Developer", isDirectory: true)
  }

  private static func appURL(forDeveloperDirectory devDir: URL) -> URL {
    // <devdir>/Contents/Developer -> <app>/
    let contents = devDir.deletingLastPathComponent()
    return contents.deletingLastPathComponent()
  }

  private static func symlinkTarget(of url: URL) -> URL? {
    let fm = FileManager.default
    guard
      let target = try? fm.destinationOfSymbolicLink(atPath: url.path)
    else {
      return nil
    }
    let resolved: URL
    if target.hasPrefix("/") {
      resolved = URL(fileURLWithPath: target)
    } else {
      resolved = url.deletingLastPathComponent().appendingPathComponent(target)
    }
    let normalized = resolved.standardizedFileURL
    return normalized.lastPathComponent == "Developer"
      ? normalized
      : normalized.appendingPathComponent("Contents/Developer", isDirectory: true)
  }

  private static func fileContents(of url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let value = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  /// Developer directories of Xcode apps in `/Applications`, newest version first.
  private static func defaultApps(in applicationDirectory: URL) -> [URL] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(
      at: applicationDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else {
      return []
    }
    let apps = entries.filter {
      $0.lastPathComponent.hasPrefix("Xcode") && $0.lastPathComponent.hasSuffix(".app")
    }
    return apps
      .sorted {
        xcodeVersion(appURL: $0).version.compare(
          xcodeVersion(appURL: $1).version, options: [.numeric]) == .orderedDescending
      }
      .map { $0.appendingPathComponent("Contents/Developer", isDirectory: true) }
  }

  private static func hasIPhoneOSSDK(at developerDirectory: URL) -> Bool {
    sdkURL(in: developerDirectory, platform: "iPhoneOS") != nil
  }

  private static func sdkURL(in developerDirectory: URL, platform: String) -> URL? {
    let sdk = developerDirectory
      .appendingPathComponent("Platforms/\(platform).platform/Developer/SDKs/\(platform).sdk")
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: sdk.path, isDirectory: &isDir)
      ? sdk : nil
  }

  /// Reads the SDK `Version` from `SDKSettings.json`, matching the canonical
  /// `iphoneos26.1` naming without invoking `xcrun`.
  private static func sdkVersion(at sdkURL: URL) -> String? {
    let settings = sdkURL.appendingPathComponent("SDKSettings.json")
    guard
      let data = try? Data(contentsOf: settings),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = object["Version"] as? String,
      !version.isEmpty
    else {
      return nil
    }
    return version
  }

  /// Reads the Xcode version and build from the app's own metadata
  /// (`Contents/version.plist`, with a `Contents/Info.plist` fallback).
  private static func xcodeVersion(appURL: URL) -> (version: String, build: String) {
    var version = "unknown"
    var build = "unknown"
    if let data = try? Data(contentsOf: appURL.appendingPathComponent("Contents/version.plist")),
      let plist = try? PropertyListSerialization.propertyList(
        from: data, format: nil) as? [String: Any]
    {
      if let v = plist["CFBundleShortVersionString"] as? String { version = v }
      if let b = plist["ProductBuildVersion"] as? String { build = b }
    }
    if version == "unknown",
      let data = try? Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
      let plist = try? PropertyListSerialization.propertyList(
        from: data, format: nil) as? [String: Any]
    {
      if let v = plist["CFBundleShortVersionString"] as? String { version = v }
    }
    return (version, build)
  }
}

/// The mutually exclusive macOS host modes selected by Xcode presence.
public enum HostSDKMode: Sendable, Equatable {
  /// Xcode with an iPhoneOS SDK is present; builds use Xcode's resources in place.
  case xcodeInPlace(XcodeInstallation)
  /// No usable Xcode; builds use an imported `stupid-app` artifact bundle.
  case importedBundle

  /// Selects the active mode the same way `doctor`/build resolve it.
  public static func detect(candidates: XcodeLocator.Candidates? = nil) -> HostSDKMode {
    if let installation = XcodeLocator.detect(candidates: candidates) {
      return .xcodeInPlace(installation)
    }
    return .importedBundle
  }
}
