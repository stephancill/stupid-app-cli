import BuildCore
import Foundation
import SDKCore

/// Runs the native CoreDevice privileged helper through the bounded
/// `ProcessRunner`. The helper is the current `stupid-app` executable invoked as
/// `coredevice-helper` so the launch owns the privileged TUN interface exactly as
/// the retired Python helper did.
public struct NativeCoreDeviceRunner: Sendable {
  public var executablePath: String
  public var sudoPath: String?
  public var pairingDirectory: URL
  public var usbmuxAddress: String?
  public var launchTimeoutSeconds: Double

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case executableMissing(String)
    case operationFailed(String, String)

    public var description: String {
      switch self {
      case .executableMissing(let path):
        return "The current stupid-app executable is not available at '\(path)'."
      case .operationFailed(let phase, let detail):
        return "CoreDevice \(phase) failed.\(detail.isEmpty ? "" : "\n\(detail)")"
      }
    }
  }

  public init(
    executablePath: String = Self.currentExecutablePath(),
    sudoPath: String? = nil,
    pairingDirectory: URL,
    usbmuxAddress: String? = nil,
    launchTimeoutSeconds: Double = 60
  ) {
    self.executablePath = executablePath
    self.sudoPath = sudoPath
    self.pairingDirectory = pairingDirectory
    self.usbmuxAddress = usbmuxAddress
    self.launchTimeoutSeconds = launchTimeoutSeconds
  }

  /// Resolves the running executable path so the helper can be re-invoked as a
  /// subcommand of the same binary.
  public static func currentExecutablePath() -> String {
    if let resolved = Bundle.main.executablePath, !resolved.isEmpty {
      return resolved
    }
    return CommandLine.arguments.first ?? "stupid-app"
  }

  public func validateEnvironment(requirePrivileges: Bool) throws {
    let executable = try resolveExecutable()
    if requirePrivileges {
      if let sudoPath {
        let resolved = try resolvePath(sudoPath)
        guard FileManager.default.isExecutableFile(atPath: resolved) else {
          throw Error.operationFailed("environment validation", "sudo is unavailable.")
        }
      } else {
        #if os(Linux)
          if geteuid() != 0 {
            throw Error.operationFailed(
              "environment validation",
              "TUN creation requires root/CAP_NET_ADMIN. Re-run with the explicit --sudo option."
            )
          }
        #endif
      }
    }
    _ = executable
  }

  public func pairUSB(udid: String) throws {
    var arguments = ["coredevice-helper", "pair-usb"]
    arguments += ["--udid", udid]
    arguments += ["--pairing-dir", pairingDirectory.path]
    if let usbmuxAddress {
      arguments += ["--usbmux", usbmuxAddress]
    }
    arguments += ["--timeout", seconds(max(launchTimeoutSeconds, 60))]

    let result = try runHelper(
      arguments: arguments, phase: "USB pairing", timeout: max(launchTimeoutSeconds, 60) + 30,
      udid: udid)
    guard Self.statusIsOK(result.stdout) else {
      throw Error.operationFailed(
        "USB pairing",
        Self.redact(detail: "helper did not report a successful pairing status", udid: udid))
    }
  }

  public func launchUSB(bundleID: String, udid: String) throws -> Int64 {
    var arguments = ["coredevice-helper", "launch-usb"]
    arguments += ["--udid", udid]
    arguments += ["--bundle-id", bundleID]
    arguments += ["--pairing-dir", pairingDirectory.path]
    if let usbmuxAddress {
      arguments += ["--usbmux", usbmuxAddress]
    }
    arguments += ["--timeout", seconds(launchTimeoutSeconds)]

    let result = try runHelper(
      arguments: arguments, phase: "USB launch", timeout: launchTimeoutSeconds + 30, udid: udid)
    guard let pid = Self.parsePID(result.stdout) else {
      throw Error.operationFailed(
        "USB launch",
        Self.redact(detail: "helper did not report a process identifier", udid: udid))
    }
    return pid
  }

  private func runHelper(
    arguments: [String], phase: String, timeout: Double, udid: String?
  ) throws -> ProcessRunner.Result {
    let executable = try resolveExecutable()

    let executableInvocation: String
    let processArguments: [String]
    if let sudoPath {
      executableInvocation = try resolvePath(sudoPath)
      processArguments = ["--preserve-env=STUPID_APP_PAIRING_HOME", executable] + arguments
    } else {
      executableInvocation = executable
      processArguments = arguments
    }

    var environment = ProcessInfo.processInfo.environment
    environment["STUPID_APP_PAIRING_HOME"] = pairingDirectory.path
    let result: ProcessRunner.Result
    do {
      result = try ProcessRunner.run(
        executable: executableInvocation,
        arguments: processArguments,
        environment: environment,
        configuration: .init(maxOutputBytes: 30_000, timeoutSeconds: timeout)
      )
    } catch {
      throw Error.operationFailed(
        phase, Self.redact(detail: String(describing: error), udid: udid))
    }
    guard result.succeeded else {
      let detail = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
      throw Error.operationFailed(phase, Self.redact(detail: detail, udid: udid))
    }
    return result
  }

  private func resolveExecutable() throws -> String {
    let resolved = HostInfo.resolveExecutable(executablePath)
    guard FileManager.default.isExecutableFile(atPath: resolved) else {
      throw Error.executableMissing(resolved)
    }
    return resolved
  }

  private func resolvePath(_ path: String) throws -> String {
    let resolved = HostInfo.resolveExecutable(path)
    guard FileManager.default.isExecutableFile(atPath: resolved) else {
      throw Error.operationFailed("environment validation", "sudo is unavailable at \(resolved).")
    }
    return resolved
  }

  private func seconds(_ value: Double) -> String {
    String(max(1, Int(value.rounded(.up))))
  }

  static func parsePID(_ output: String) -> Int64? {
    guard
      let data = output.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["status"] as? String == "ok",
      let pid = object["pid"] as? Int64,
      pid > 0
    else {
      return nil
    }
    return pid
  }

  static func statusIsOK(_ output: String) -> Bool {
    guard
      let data = output.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["status"] as? String == "ok"
    else {
      return false
    }
    return true
  }

  static func redact(detail: String, udid: String?) -> String {
    guard let udid, !udid.isEmpty else { return detail }
    return detail.replacingOccurrences(of: udid, with: "<device-udid>")
  }
}
