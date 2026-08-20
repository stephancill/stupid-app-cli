import ArgumentParser
import DeviceKit
import Foundation

/// Hidden privileged helper command that performs CoreDevice operations natively.
/// `run --usb` invokes this through `sudo` so the process owns the TUN interface,
/// mirroring the retired Python helper boundary. The helper prints a single JSON
/// status line and nothing else.
struct CoreDeviceHelperCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "coredevice-helper",
    abstract: "Privileged native CoreDevice operations (run via sudo).",
    subcommands: [
      CoreDevicePairCommand.self,
      CoreDeviceLaunchCommand.self,
      CoreDeviceNetworkRunCommand.self,
      CoreDeviceNetworkCrashCommand.self,
    ]
  )
}

struct CoreDevicePairCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pair-usb",
    abstract: "Bootstrap CoreDevice remote pairing over a native USB tunnel."
  )

  @Option(name: .customLong("udid"), help: "Target device UDID.")
  var udid: String

  @Option(name: .customLong("pairing-dir"), help: "Pairing record directory.")
  var pairingDirectory: String

  @Option(name: .customLong("usbmux"), help: "usbmuxd address (unix socket or HOST:PORT).")
  var usbmuxAddress: String?

  @Option(name: .customLong("timeout"), help: "Maximum seconds for pairing phases.")
  var timeout: Double = 60

  func run() throws {
    let pairer = CoreDeviceRemotePairer(
      usbmuxAddress: usbmuxAddress,
      pairingDirectory: URL(fileURLWithPath: pairingDirectory, isDirectory: true),
      timeoutSeconds: timeout,
      progress: { message in
        FileHandle.standardError.write(Data("\(message)\n".utf8))
      }
    )
    try pairer.pair(udid: udid)
    print(#"{"status":"ok","operation":"pair-usb"}"#)
  }
}

struct CoreDeviceLaunchCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "launch-usb",
    abstract: "Launch an installed application through a native CoreDevice USB tunnel."
  )

  @Option(name: .customLong("udid"), help: "Target device UDID.")
  var udid: String

  @Option(name: .customLong("bundle-id"), help: "Installed bundle identifier.")
  var bundleID: String

  @Option(name: .customLong("pairing-dir"), help: "Pairing record directory.")
  var pairingDirectory: String

  @Option(name: .customLong("usbmux"), help: "usbmuxd address (unix socket or HOST:PORT).")
  var usbmuxAddress: String?

  @Option(name: .customLong("timeout"), help: "Maximum seconds for launch phases.")
  var timeout: Double = 60

  func run() throws {
    let launcher = CoreDeviceUSBLauncher(
      usbmuxAddress: usbmuxAddress,
      pairingDirectory: URL(fileURLWithPath: pairingDirectory, isDirectory: true),
      timeoutSeconds: timeout,
      progress: { message in
        FileHandle.standardError.write(Data("\(message)\n".utf8))
      }
    )
    let pid = try launcher.launch(bundleID: bundleID, udid: udid)
    let output = """
      {"status":"ok","operation":"launch-usb","pid":\(pid)}
      """
    print(output)
  }
}

struct CoreDeviceNetworkRunCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run-network",
    abstract: "Install and launch over a native CoreDevice network tunnel."
  )

  @Option(name: .customLong("udid"), help: "Target device UDID.")
  var udid: String

  @Option(name: .customLong("bundle-id"), help: "Installed bundle identifier.")
  var bundleID: String

  @Option(name: .customLong("ipa"), help: "Development IPA to install.")
  var ipaPath: String

  @Option(name: .customLong("pairing-dir"), help: "Pairing record directory.")
  var pairingDirectory: String

  @Option(name: .customLong("discovery-timeout"), help: "Maximum seconds for discovery.")
  var discoveryTimeout: Double = 15

  @Option(name: .customLong("install-timeout"), help: "Maximum seconds for installation.")
  var installTimeout: Double = 300

  @Option(name: .customLong("launch-timeout"), help: "Maximum seconds for app launch.")
  var launchTimeout: Double = 60

  func run() throws {
    let runner = NativeNetworkRunner(
      pairingDirectory: URL(fileURLWithPath: pairingDirectory, isDirectory: true),
      udid: udid,
      ipa: URL(fileURLWithPath: ipaPath),
      bundleID: bundleID,
      discoveryTimeoutSeconds: discoveryTimeout,
      installTimeoutSeconds: installTimeout,
      launchTimeoutSeconds: launchTimeout,
      progress: { message in
        FileHandle.standardError.write(Data("\(message)\n".utf8))
      }
    )
    let pid = try runner.installAndLaunch()
    let output = """
      {"status":"ok","operation":"run-network","pid":\(pid)}
      """
    print(output)
  }
}

struct CoreDeviceNetworkCrashCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "crash-network",
    abstract: "Pull and print the newest crash report over the native CoreDevice network tunnel."
  )

  @Option(name: .customLong("udid"), help: "Target device UDID.")
  var udid: String

  @Option(name: .customLong("pairing-dir"), help: "Pairing record directory.")
  var pairingDirectory: String

  @Option(name: .customLong("filter"), help: "Substring to match crash-report file names.")
  var filter: String?

  @Option(name: .customLong("discovery-timeout"), help: "Maximum seconds for discovery.")
  var discoveryTimeout: Double = 15

  func run() throws {
    let client = CrashReportNetworkClient(
      pairingDirectory: URL(fileURLWithPath: pairingDirectory, isDirectory: true),
      udid: udid,
      discoveryTimeoutSeconds: discoveryTimeout,
      progress: { message in
        FileHandle.standardError.write(Data("\(message)\n".utf8))
      }
    )
    let report = try client.latestParsedReport(nameFilter: filter)
    // Emit the parsed report on stdout as JSON so the invoking `device crash`
    // can render it; diagnostics go to stderr.
    print(try crashReportJSON(report))
  }

  private func crashReportJSON(_ report: CrashReport) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(report)
    guard let text = String(data: data, encoding: .utf8) else {
      throw CrashReportJSONError.encoding
    }
    return text
  }
}

enum CrashReportJSONError: Error, CustomStringConvertible {
  case encoding

  var description: String {
    "The crash report could not be serialized to JSON."
  }
}
