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
