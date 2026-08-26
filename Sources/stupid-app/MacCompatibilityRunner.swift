import BuildCore
import Foundation

#if os(macOS)
  import AppKit
#endif

struct MacCompatibilityRunner {
  struct Device: Decodable, Equatable {
    let identifier: String
    let platform: String
    let simulator: Bool
    let available: Bool
    let name: String
  }

  static func localDevice() throws -> Device {
    #if os(macOS) && arch(arm64)
      let result = try ProcessRunner.run(
        executable: "/usr/sbin/system_profiler",
        arguments: ["-json", "SPHardwareDataType"])
      guard result.succeeded else {
        throw Error.deviceLookupFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
      }
      return try decodeLocalDevice(Data(result.stdout.utf8))
    #else
      throw Error.unsupportedHost
    #endif
  }

  static func decodeLocalDevice(_ data: Data) throws -> Device {
    struct Hardware: Decodable {
      let machineName: String
      let provisioningUDID: String

      enum CodingKeys: String, CodingKey {
        case machineName = "machine_name"
        case provisioningUDID = "provisioning_UDID"
      }
    }
    struct Report: Decodable {
      let hardware: [Hardware]

      enum CodingKeys: String, CodingKey {
        case hardware = "SPHardwareDataType"
      }
    }
    guard let hardware = try JSONDecoder().decode(Report.self, from: data).hardware.first else {
      throw Error.localDeviceUnavailable
    }
    return Device(
      identifier: hardware.provisioningUDID,
      platform: "com.apple.platform.macosx",
      simulator: false,
      available: true,
      name: hardware.machineName)
  }

  /// Enumerates the `.appex` bundles nested under `PlugIns/` of an iOS app wrapper.
  /// These are the iOS-style extensions that macOS runs in the compatibility
  /// environment (for this wallet, the Safari Web Extension). LaunchServices
  /// registration of the containing wrapper already elects them for PlugInKit, but we
  /// also register each one explicitly so the record is present and diagnosable even if
  /// nested-bundle election is delayed.
  static func enumerateNestedAppExtensions(in appURL: URL) -> [URL] {
    let pluginsDir = appURL.appendingPathComponent("PlugIns", isDirectory: true)
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: pluginsDir, includingPropertiesForKeys: nil)
    else { return [] }
    return entries
      .filter { $0.pathExtension == "appex" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// Registers every nested `.appex` with PlugInKit after the wrapper is staged and
  /// registered with LaunchServices. `pluginkit -a` is the public, idempotent way to
  /// add a plugin; it does not carry private entitlements. A registration failure is a
  /// loud warning rather than an install abort because the containing-app LaunchServices
  /// registration already elects nested extensions, and Safari can still run them.
  @discardableResult
  static func registerNestedAppExtensions(in appURL: URL) throws -> [URL] {
    let appexes = enumerateNestedAppExtensions(in: appURL)
    for appex in appexes {
      let result = try ProcessRunner.run(
        executable: "/usr/bin/pluginkit",
        arguments: ["-a", appex.path])
      if !result.succeeded {
        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
        print(
          "Warning: could not explicitly register \(appex.lastPathComponent) with PlugInKit: \(detail)"
        )
      }
    }
    return appexes
  }

  static func installAndLaunch(appURL: URL) throws -> URL {
    #if os(macOS) && arch(arm64)
      if let bundleID = Bundle(url: appURL)?.bundleIdentifier {
        for application in NSRunningApplication.runningApplications(
          withBundleIdentifier: bundleID)
        {
          _ = application.terminate()
          let deadline = Date().addingTimeInterval(5)
          while !application.isTerminated && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
          }
          if !application.isTerminated {
            _ = application.forceTerminate()
          }
        }
      }

      let installedURL = appURL.deletingLastPathComponent()
        .appendingPathComponent(".MacInstall", isDirectory: true)
        .appendingPathComponent(
          appURL.lastPathComponent, isDirectory: true)
      let wrapper = installedURL.appendingPathComponent("Wrapper", isDirectory: true)
      let wrappedApp = wrapper.appendingPathComponent(
        appURL.lastPathComponent, isDirectory: true)
      let fileManager = FileManager.default
      if fileManager.fileExists(atPath: installedURL.path) {
        try fileManager.removeItem(at: installedURL)
      }
      try fileManager.createDirectory(at: wrapper, withIntermediateDirectories: true)
      try fileManager.copyItem(at: appURL, to: wrappedApp)
      try fileManager.createSymbolicLink(
        atPath: installedURL.appendingPathComponent("WrappedBundle").path,
        withDestinationPath: "Wrapper/\(appURL.lastPathComponent)")

      let register = try ProcessRunner.run(
        executable:
          "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
        arguments: ["-f", installedURL.path])
      guard register.succeeded else {
        throw Error.installFailed(register.stderr.isEmpty ? register.stdout : register.stderr)
      }

      let nestedExtensions = try registerNestedAppExtensions(in: wrappedApp)
      if !nestedExtensions.isEmpty {
        print(
          "Registered \(nestedExtensions.count) nested app extension(s) with PlugInKit: "
            + nestedExtensions.map(\.lastPathComponent).joined(separator: ", "))
      }

      let launch = try ProcessRunner.run(
        executable: "/usr/bin/open", arguments: [installedURL.path])
      guard launch.succeeded else {
        throw Error.launchFailed(launch.stderr.isEmpty ? launch.stdout : launch.stderr)
      }
      return installedURL
    #else
      throw Error.unsupportedHost
    #endif
  }

  enum Error: Swift.Error, CustomStringConvertible {
    case unsupportedHost
    case deviceLookupFailed(String)
    case localDeviceUnavailable
    case installFailed(String)
    case launchFailed(String)

    var description: String {
      switch self {
      case .unsupportedHost:
        return "Local iOS-on-Mac runs require an Apple Silicon Mac."
      case .deviceLookupFailed(let detail):
        return "Could not read this Mac's provisioning identity. \(detail)"
      case .localDeviceUnavailable:
        return "This Mac does not report a provisioning UDID for local iPhone/iPad apps."
      case .installFailed(let detail):
        return "Could not install the iOS app on this Mac. \(detail)"
      case .launchFailed(let detail):
        return "The iOS app installed on this Mac but could not be launched. \(detail)"
      }
    }
  }
}
