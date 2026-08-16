import BuildCore
import Foundation
import SDKCore

/// Runs the pinned pymobiledevice3 CoreDevice bridge with an explicit privilege boundary.
public struct CoreDeviceRunner: Sendable {
  public var pythonPath: String
  public var sudoPath: String?
  public var helperPath: String?
  public var pairingDirectory: URL
  public var usbmuxAddress: String?
  public var discoveryTimeoutSeconds: Double
  public var installTimeoutSeconds: Double
  public var launchTimeoutSeconds: Double

  public init(
    pythonPath: String,
    sudoPath: String? = nil,
    helperPath: String? = nil,
    pairingDirectory: URL,
    usbmuxAddress: String? = nil,
    discoveryTimeoutSeconds: Double = 15,
    installTimeoutSeconds: Double = 300,
    launchTimeoutSeconds: Double = 60
  ) {
    self.pythonPath = pythonPath
    self.sudoPath = sudoPath
    self.helperPath = helperPath
    self.pairingDirectory = pairingDirectory
    self.usbmuxAddress = usbmuxAddress
    self.discoveryTimeoutSeconds = discoveryTimeoutSeconds
    self.installTimeoutSeconds = installTimeoutSeconds
    self.launchTimeoutSeconds = launchTimeoutSeconds
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case binaryMissing(String)
    case helperMissing
    case operationFailed(String, String)

    public var description: String {
      switch self {
      case .binaryMissing(let path):
        return "The required executable is not available at '\(path)'."
      case .helperMissing:
        return
          "The CoreDevice helper is missing or unreadable. Reinstall stupid-app or correct --coredevice-helper."
      case .operationFailed(let phase, let detail):
        return "CoreDevice \(phase) failed.\(detail.isEmpty ? "" : "\n\(detail)")"
      }
    }
  }

  public func validateEnvironment(requirePrivileges: Bool) throws {
    var arguments = ["check"]
    if requirePrivileges {
      arguments.append("--require-root")
    }
    _ = try run(phase: "environment validation", arguments: arguments, timeout: 30)
  }

  public func pairUSB(udid: String) throws {
    var arguments = [
      "pair-usb",
      "--udid", udid,
      "--timeout", seconds(discoveryTimeoutSeconds),
    ]
    if let usbmuxAddress = resolvedUsbmuxAddress {
      arguments += ["--usbmux", usbmuxAddress]
    }
    _ = try run(
      phase: "USB pairing",
      arguments: arguments,
      timeout: max(60, discoveryTimeoutSeconds * 3),
      udid: udid
    )
  }

  public func launchUSB(bundleID: String, udid: String) throws {
    var arguments = [
      "launch-usb",
      "--udid", udid,
      "--bundle-id", bundleID,
      "--timeout", seconds(launchTimeoutSeconds),
    ]
    if let usbmuxAddress = resolvedUsbmuxAddress {
      arguments += ["--usbmux", usbmuxAddress]
    }
    _ = try run(
      phase: "USB launch",
      arguments: arguments,
      timeout: launchTimeoutSeconds + 30,
      udid: udid
    )
  }

  public func installAndLaunchNetwork(ipa: URL, bundleID: String, udid: String) throws {
    let arguments = [
      "run-network",
      "--udid", udid,
      "--ipa", ipa.path,
      "--bundle-id", bundleID,
      "--discovery-timeout", seconds(discoveryTimeoutSeconds),
      "--install-timeout", seconds(installTimeoutSeconds),
      "--launch-timeout", seconds(launchTimeoutSeconds),
    ]
    _ = try run(
      phase: "network install and launch",
      arguments: arguments,
      timeout: discoveryTimeoutSeconds + installTimeoutSeconds + launchTimeoutSeconds + 30,
      udid: udid
    )
  }

  private func run(
    phase: String,
    arguments: [String],
    timeout: Double,
    udid: String? = nil
  ) throws -> ProcessRunner.Result {
    try preparePairingDirectory()
    let python = try resolveExecutable(pythonPath)
    let helper = try resolvedHelper()

    let executable: String
    let processArguments: [String]
    if let sudoPath {
      executable = try resolveExecutable(sudoPath)
      processArguments =
        [
          "--preserve-env=STUPID_APP_PAIRING_HOME", python, helper.path,
        ] + arguments
    } else {
      executable = python
      processArguments = [helper.path] + arguments
    }

    var environment = ProcessInfo.processInfo.environment
    environment["STUPID_APP_PAIRING_HOME"] = pairingDirectory.path
    let result: ProcessRunner.Result
    do {
      result = try ProcessRunner.run(
        executable: executable,
        arguments: processArguments,
        environment: environment,
        configuration: .init(maxOutputBytes: 30_000, timeoutSeconds: timeout)
      )
    } catch {
      throw Error.operationFailed(
        phase,
        Self.redact(detail: String(describing: error), udid: udid)
      )
    }
    guard result.succeeded else {
      let detail = [result.stdout, result.stderr]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
      throw Error.operationFailed(phase, Self.redact(detail: detail, udid: udid))
    }
    return result
  }

  private func preparePairingDirectory() throws {
    try FileManager.default.createDirectory(
      at: pairingDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: pairingDirectory.path
    )
  }

  private var resolvedUsbmuxAddress: String? {
    if let usbmuxAddress {
      return usbmuxAddress
    }
    let socket = "/var/run/usbmuxd"
    return FileManager.default.fileExists(atPath: socket) ? socket : nil
  }

  private func resolveExecutable(_ path: String) throws -> String {
    let resolved = HostInfo.resolveExecutable(path)
    guard FileManager.default.isExecutableFile(atPath: resolved) else {
      throw Error.binaryMissing(resolved)
    }
    return resolved
  }

  private func resolvedHelper() throws -> URL {
    if let helperPath {
      let helper = URL(fileURLWithPath: helperPath)
      guard FileManager.default.isReadableFile(atPath: helper.path) else {
        throw Error.helperMissing
      }
      return helper
    }
    guard
      let helper = Bundle.module.url(
        forResource: "pymobiledevice3_helper",
        withExtension: "py",
        subdirectory: "Resources")
    else {
      throw Error.helperMissing
    }
    return helper
  }

  private func seconds(_ value: Double) -> String {
    String(max(1, Int(value.rounded(.up))))
  }

  static func redact(detail: String, udid: String?) -> String {
    guard let udid, !udid.isEmpty else { return detail }
    return detail.replacingOccurrences(of: udid, with: "<device-udid>")
  }
}
