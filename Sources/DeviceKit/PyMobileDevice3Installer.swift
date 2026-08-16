import BuildCore
import Foundation
import SDKCore

/// Gate 3 device transport: the pinned `pymobiledevice3` CLI over USB (`usbmux`).
/// The transport is replaceable; `stupid-app run` depends only on `DeviceInstaller`.
public struct PyMobileDevice3Installer: DeviceInstaller {
  public var executablePath: String
  /// Optional usbmuxd address passed as `--usbmux`. When nil, the platform
  /// default is used; on Linux a running systemd usbmuxd socket is detected.
  public var usbmuxAddress: String?
  public var installTimeoutSeconds: Double
  public var launchTimeoutSeconds: Double
  public var discoveryTimeoutSeconds: Double

  public init(
    executablePath: String = "pymobiledevice3",
    usbmuxAddress: String? = nil,
    installTimeoutSeconds: Double = 300,
    launchTimeoutSeconds: Double = 60,
    discoveryTimeoutSeconds: Double = 30
  ) {
    self.executablePath = executablePath
    self.usbmuxAddress = usbmuxAddress
    self.installTimeoutSeconds = installTimeoutSeconds
    self.launchTimeoutSeconds = launchTimeoutSeconds
    self.discoveryTimeoutSeconds = discoveryTimeoutSeconds
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case binaryMissing(String)
    case installFailed(String)
    case launchFailed(String)
    case discoveryFailed(String)

    public var description: String {
      switch self {
      case .binaryMissing(let path):
        return
          "The pymobiledevice3 CLI is not available at '\(path)'. Install it on the deployment host (e.g. `pip install pymobiledevice3`)."
      case .installFailed(let detail):
        return
          "Installation failed.\n\(detail)\nConfirm the device is USB-connected, unlocked, and trusted (and that no other device tool is holding usbmuxd)."
      case .launchFailed(let detail):
        return
          "Launch failed.\n\(detail)\nConfirm Developer Mode is enabled on the device and the app is installed."
      case .discoveryFailed(let detail):
        return "Could not list USB devices.\n\(detail)"
      }
    }
  }

  public func install(ipa: URL, udid: String?) throws {
    let executable = try resolvedExecutable()
    var arguments = ["apps", "install", ipa.path, "--developer"]
    arguments += usbmuxArguments()
    if let udid {
      arguments += ["--udid", udid]
    }
    let result: ProcessRunner.Result
    do {
      result = try ProcessRunner.run(
        executable: executable,
        arguments: arguments,
        configuration: .init(maxOutputBytes: 20_000, timeoutSeconds: installTimeoutSeconds)
      )
    } catch {
      throw Error.installFailed(Self.redact(detail: String(describing: error), udid: udid))
    }
    guard result.succeeded else {
      throw Error.installFailed(
        Self.redact(detail: result.stderr.isEmpty ? result.stdout : result.stderr, udid: udid))
    }
  }

  public func launch(bundleID: String, udid: String?) throws {
    let executable = try resolvedExecutable()
    var arguments = ["developer", "dvt", "launch", bundleID]
    arguments += usbmuxArguments()
    if let udid {
      arguments += ["--udid", udid]
    }
    let result: ProcessRunner.Result
    do {
      result = try ProcessRunner.run(
        executable: executable,
        arguments: arguments,
        configuration: .init(maxOutputBytes: 20_000, timeoutSeconds: launchTimeoutSeconds)
      )
    } catch {
      throw Error.launchFailed(Self.redact(detail: String(describing: error), udid: udid))
    }
    guard result.succeeded else {
      throw Error.launchFailed(
        Self.redact(detail: result.stderr.isEmpty ? result.stdout : result.stderr, udid: udid))
    }
  }

  /// Resolves the `--usbmux` argument value: an explicit address, or the Linux
  /// systemd usbmuxd unix socket when present.
  private func usbmuxArguments() -> [String] {
    let address = usbmuxAddress ?? defaultLinuxSocket
    guard let address else { return [] }
    return ["--usbmux", address]
  }

  private var defaultLinuxSocket: String? {
    guard usbmuxAddress == nil else { return nil }
    let socket = "/var/run/usbmuxd"
    return FileManager.default.fileExists(atPath: socket) ? socket : nil
  }

  public func usbDeviceUDIDs() throws -> [String] {
    let executable = try resolvedExecutable()
    var arguments = ["usbmux", "list", "--usb", "--simple"]
    arguments += usbmuxArguments()
    let result: ProcessRunner.Result
    do {
      result = try ProcessRunner.run(
        executable: executable,
        arguments: arguments,
        configuration: .init(maxOutputBytes: 20_000, timeoutSeconds: discoveryTimeoutSeconds)
      )
    } catch {
      throw Error.discoveryFailed(String(describing: error))
    }
    guard result.succeeded else {
      throw Error.discoveryFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
    }
    return Self.parseUDIDList(result.stdout)
  }

  /// Normalizes `usbmux list --usb --simple` output into UDID strings, ignoring
  /// empty lines and separating by whitespace.
  public static func parseUDIDList(_ output: String) -> [String] {
    if let data = output.data(using: .utf8),
      let values = try? JSONDecoder().decode([String].self, from: data)
    {
      return values.filter { !$0.isEmpty }
    }
    return
      output
      .split(whereSeparator: { $0.isWhitespace || $0 == "\n" })
      .map(String.init)
      .filter { !$0.isEmpty }
  }

  private func resolvedExecutable() throws -> String {
    let resolved = HostInfo.resolveExecutable(executablePath)
    guard FileManager.default.isExecutableFile(atPath: resolved) else {
      throw Error.binaryMissing(resolved)
    }
    return resolved
  }

  static func redact(detail: String, udid: String?) -> String {
    guard let udid, !udid.isEmpty else { return detail }
    return detail.replacingOccurrences(of: udid, with: "<device-udid>")
  }
}
