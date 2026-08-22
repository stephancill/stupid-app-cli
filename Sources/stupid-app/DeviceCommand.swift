import ASCKit
import ArgumentParser
import DeviceKit
import Foundation

struct DeviceCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "device",
    abstract: "Manage local device pairing, diagnostics, and inventory.",
    subcommands: [DeviceListCommand.self, DevicePairCommand.self, DeviceCrashCommand.self]
  )
}

struct DeviceListCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List locally known devices (USB and saved network pairing records)."
  )

  @Option(name: .customLong("usbmux"), help: "usbmuxd address (unix socket or HOST:PORT).")
  var usbmuxAddress: String?

  @Option(name: .customLong("home"), help: "Credential store directory.")
  var home: String?

  mutating func run() throws {
    let homeURL =
      home.map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".stupid-app/credentials", isDirectory: true)

    print("USB devices:")
    do {
      let discovery = USBMuxClient(address: usbmuxAddress)
      let udids = try discovery.usbDeviceUDIDs()
      if udids.isEmpty {
        print("  (none connected)")
      } else {
        for udid in udids { print("  \(udid)") }
      }
    } catch {
      print("  (unavailable: \(error))")
    }

    print("Saved network pairing records:")
    let pairingDirectory = homeURL.appendingPathComponent("pairing", isDirectory: true)
    let saved = (try? RemotePairing.savedPairings(in: pairingDirectory)) ?? []
    if saved.isEmpty {
      print("  (none)")
    } else {
      for record in saved {
        if let udid = record.udid {
          print("  \(record.identifier) -> \(udid)")
        } else {
          print("  \(record.identifier) -> (unmapped; re-run `stupid-app device pair --usb`)")
        }
      }
    }
  }
}

struct DevicePairCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pair",
    abstract: "Bootstrap lockdown and CoreDevice remote pairing over USB."
  )

  @Flag(name: .customLong("usb"), help: "Pair the USB-connected device.")
  var usb = false

  @Option(
    name: .customLong("udid"),
    help: "Target device UDID; inferred when one USB device is connected.")
  var udid: String?

  @Option(
    name: .customLong("sudo"), help: "Explicit path to sudo for the privileged CoreDevice helper.")
  var sudoPath: String?

  @Option(name: .customLong("usbmux"), help: "usbmuxd address (unix socket or HOST:PORT).")
  var usbmuxAddress: String?

  @Option(name: .customLong("timeout"), help: "Maximum seconds for discovery and pairing phases.")
  var timeout: Double = 30

  @Flag(
    name: .customLong("replace-lockdown-record"),
    help: "Generate and store a new lockdown trust record instead of reusing the existing record.")
  var replaceLockdownRecord = false

  @Option(name: .customLong("home"), help: "Credential store directory.")
  var home: String?

  mutating func run() async throws {
    guard usb else {
      throw DevicePairError.usbRequired
    }

    let homeURL =
      home.map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".stupid-app/credentials", isDirectory: true)
    let store = CredentialStore(home: homeURL)
    try store.ensureDirectory()

    let targetUDID: String
    if let udid {
      targetUDID = udid
    } else {
      let discovery = USBMuxClient(address: usbmuxAddress, timeoutSeconds: timeout)
      let devices = try discovery.usbDeviceUDIDs()
      guard devices.count == 1 else {
        throw DevicePairError.deviceSelection(devices.count)
      }
      targetUDID = devices[0]
    }

    let pairer = LockdownPairer(
      usbmuxAddress: usbmuxAddress,
      pairingDirectory: homeURL.appendingPathComponent("pairing", isDirectory: true),
      timeoutSeconds: timeout,
      progress: { print($0) }
    )
    let pairingResult = try pairer.pair(
      udid: targetUDID,
      replaceExistingRecord: replaceLockdownRecord
    )
    switch pairingResult {
    case .reusedExistingRecord:
      print("Reused the existing native lockdown pairing.")
    case .createdRecord:
      print("Created a new native lockdown pairing.")
    }

    let runner = NativeCoreDeviceRunner(
      sudoPath: sudoPath,
      pairingDirectory: homeURL.appendingPathComponent("pairing", isDirectory: true),
      usbmuxAddress: usbmuxAddress,
      launchTimeoutSeconds: timeout
    )
    try runner.validateEnvironment(requirePrivileges: true)
    print("Pairing the selected USB device...")
    try runner.pairUSB(udid: targetUDID)
    print("Stored the CoreDevice remote pairing record in the credential store.")
  }
}

enum DevicePairError: Error, CustomStringConvertible {
  case usbRequired
  case deviceSelection(Int)

  var description: String {
    switch self {
    case .usbRequired:
      return "Device pairing currently requires --usb."
    case .deviceSelection(let count):
      return
        "Expected exactly one USB-connected device, found \(count). Pass --udid to select a device."
    }
  }
}

struct DeviceCrashCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "crash",
    abstract: "Inspect an iOS crash report (.ips), from a file or a paired device."
  )

  @Option(
    name: .customLong("path"),
    help: "Path to a local .ips crash report to parse.")
  var path: String?

  @Option(
    name: .customLong("udid"),
    help: "Physical-device UDID (usbmux serial) to pull the newest crash report from.")
  var udid: String?

  @Flag(
    name: .customLong("network"),
    help: "Pull the crash report over the wireless (CoreDevice network) tunnel instead of USB.")
  var network = false

  @Option(
    name: .customLong("sudo"), help: "Explicit path to sudo for the privileged network helper.")
  var sudoPath: String?

  @Option(
    name: .customLong("filter"),
    help: "Substring to match report file names when pulling from a device.")
  var filter: String?

  @Option(name: .customLong("home"), help: "Credential store directory.")
  var home: String?

  @Flag(
    name: .customLong("json"),
    help: "Print the parsed fields as JSON instead of a human summary.")
  var json = false

  mutating func run() async throws {
    let report: CrashReport
    if let path {
      report = try Self.load(path: path)
    } else if let udid {
      report = try loadFromDevice(udid: udid)
    } else {
      throw DeviceCrashError.sourceRequired
    }
    if json {
      print(Self.jsonString(of: report))
    } else {
      print(report.summary())
    }
  }

  private func loadFromDevice(udid: String) throws -> CrashReport {
    let homeURL =
      home.map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".stupid-app/credentials", isDirectory: true)
    let pairingDir = homeURL.appendingPathComponent("pairing", isDirectory: true)
    if network {
      do {
        let runner = NativeCoreDeviceRunner(
          sudoPath: sudoPath,
          pairingDirectory: pairingDir,
          launchTimeoutSeconds: 60
        )
        return try runner.pullNetworkCrash(
          udid: udid, nameFilter: filter, discoveryTimeoutSeconds: 30)
      } catch {
        throw DeviceCrashError.device(String(describing: error))
      }
    }
    let client = CrashReportClient(
      pairingDirectory: pairingDir,
      progress: { if !$0.isEmpty { print($0) } }
    )
    do {
      return try client.latestParsedReportUSB(udid: udid, nameFilter: filter)
    } catch {
      throw DeviceCrashError.device(String(describing: error))
    }
  }

  /// Loads and parses a local `.ips` report into a `CrashReport`. Kept as a pure
  /// entry point so parsing is testable without a device or stdout capture.
  static func load(path: String?) throws -> CrashReport {
    guard let path else {
      throw DeviceCrashError.pathRequired
    }
    let url = URL(fileURLWithPath: path)
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw DeviceCrashError.unreadable(path)
    }
    guard let buffer = String(data: data, encoding: .utf8) else {
      throw DeviceCrashError.notUTF8(path)
    }
    do {
      return try CrashReportParsing.parse(buffer)
    } catch {
      throw DeviceCrashError.parse(String(describing: error))
    }
  }

  static func jsonString(of report: CrashReport) -> String {
    let formatter = JSONEncoder()
    formatter.outputFormatting = [.sortedKeys, .prettyPrinted]
    guard let data = try? formatter.encode(report) else {
      return "{}"
    }
    return String(data: data, encoding: .utf8) ?? "{}"
  }
}

enum DeviceCrashError: Error, CustomStringConvertible {
  case sourceRequired
  case pathRequired
  case unreadable(String)
  case notUTF8(String)
  case parse(String)
  case device(String)

  var description: String {
    switch self {
    case .sourceRequired:
      return "Provide either a --path to a crash report file or a --udid to pull from a device."
    case .pathRequired:
      return "Provide a --path to a .ips crash report to parse."
    case .unreadable(let path):
      return "Could not read the crash report at \(path). Confirm it exists and is a regular file."
    case .notUTF8(let path):
      return "The file at \(path) is not valid UTF-8 text and is not a supported .ips report."
    case .parse(let detail):
      return "The crash report could not be parsed: \(detail)."
    case .device(let detail):
      return "The on-device crash report could not be retrieved: \(detail)."
    }
  }
}
