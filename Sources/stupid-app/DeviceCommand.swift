import ASCKit
import ArgumentParser
import DeviceKit
import Foundation

struct DeviceCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "device",
    abstract: "Manage local device pairing, diagnostics, and inventory.",
    subcommands: [
      DeviceListCommand.self, DevicePairCommand.self, DeviceCrashCommand.self,
      DeviceContainerCommand.self,
    ]
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

  @Flag(name: .customLong("json"), help: "Print machine-readable JSON instead of a human summary.")
  var json = false

  mutating func run() throws {
    let homeURL =
      home.map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".stupid-app/credentials", isDirectory: true)

    let pairingDirectory = homeURL.appendingPathComponent("pairing", isDirectory: true)
    let pairingRecords = (try? RemotePairing.savedPairings(in: pairingDirectory)) ?? []

    let usbUDIDs: [String]
    let usbError: String?
    do {
      let discovery = USBMuxClient(address: usbmuxAddress)
      usbUDIDs = try discovery.usbDeviceUDIDs()
      usbError = nil
    } catch {
      usbUDIDs = []
      usbError = String(describing: error)
    }

    if json {
      let payload = DeviceListJSON(
        usbDevices: usbUDIDs,
        usbError: usbError,
        networkPairings: pairingRecords.map {
          NetworkPairingJSON(identifier: $0.identifier, udid: $0.udid)
        }
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      print(String(data: try encoder.encode(payload), encoding: .utf8) ?? "{}")
      return
    }

    print("USB devices:")
    if usbUDIDs.isEmpty {
      print("  (none connected)")
    } else {
      for udid in usbUDIDs { print("  \(udid)") }
    }
    if let usbError {
      print("  (unavailable: \(usbError))")
    }

    print("Saved network pairing records:")
    if pairingRecords.isEmpty {
      print("  (none)")
    } else {
      for record in pairingRecords {
        if let udid = record.udid {
          print("  \(record.identifier) -> \(udid)")
        } else {
          print("  \(record.identifier) -> (unmapped; re-run `stupid-app device pair --usb`)")
        }
      }
    }
  }

  private struct DeviceListJSON: Encodable {
    var usbDevices: [String]
    var usbError: String?
    var networkPairings: [NetworkPairingJSON]
  }

  private struct NetworkPairingJSON: Encodable {
    var identifier: String
    var udid: String?
  }
}

struct DevicePairCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pair",
    abstract: "Bootstrap CoreDevice remote pairing over USB, or over the network (Apple TV)."
  )

  @Flag(name: .customLong("usb"), help: "Pair the USB-connected device.")
  var usb = false

  @Flag(
    name: .customLong("network"),
    help:
      "Pair a device waiting on the network, such as an Apple TV on Settings > Remotes and Devices > Remote App and Devices.")
  var network = false

  @Option(
    name: .customLong("host"),
    help: "Network pairing: the device's address (discovered when omitted).")
  var host: String?

  @Option(
    name: .customLong("port"),
    help: "Network pairing: the device's manual-pairing port (discovered when omitted).")
  var port: UInt16?

  @Option(
    name: .customLong("pin"),
    help: "Network pairing: the PIN the device shows (prompted for when omitted).")
  var pin: String?

  @Option(
    name: .customLong("pin-file"),
    help:
      "Network pairing: wait for this file and read the PIN from it (for non-interactive runs).")
  var pinFile: String?

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
    guard usb != network else {
      throw DevicePairError.usbRequired
    }
    if network {
      return try pairNetwork()
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

extension DevicePairCommand {
  private func pairNetwork() throws {
    let homeURL =
      home.map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".stupid-app/credentials", isDirectory: true)
    try CredentialStore(home: homeURL).ensureDirectory()

    let targetHost: String
    let targetPort: UInt16
    var advertisedIdentifier: String?
    if let host, let port {
      targetHost = host
      targetPort = port
    } else {
      print("Looking for a device waiting to pair...")
      let candidates = try RemotepairingDiscovery.browseManualPairing(timeout: min(timeout, 5))
        .compactMap { advertisement -> (String, String, UInt16, String?)? in
          guard let port = advertisement.port, let port = UInt16(exactly: port),
            let address =
              advertisement.addresses.first(where: { !$0.ip.contains(":") })
              ?? advertisement.addresses.first
          else { return nil }
          return (
            advertisement.instance, address.scopedIP, port,
            advertisement.properties["identifier"]
          )
        }
      guard candidates.count == 1, let candidate = candidates.first else {
        throw DevicePairError.networkDeviceSelection(candidates.map(\.0))
      }
      print("Found \(candidate.0) at \(candidate.1):\(candidate.2)")
      targetHost = candidate.1
      targetPort = candidate.2
      advertisedIdentifier = candidate.3
    }

    let suppliedPIN = pin
    let pinFileURL = pinFile.map { URL(fileURLWithPath: $0) }
    let pinWait = max(timeout, 120)
    let pairer = NetworkManualPairer(
      host: targetHost, port: targetPort, advertisedIdentifier: advertisedIdentifier,
      pairingDirectory: homeURL.appendingPathComponent("pairing", isDirectory: true),
      timeoutSeconds: max(timeout, 120),
      progress: { print($0) })
    let peer = try pairer.pair(pinProvider: {
      if let suppliedPIN { return suppliedPIN }
      if let pinFileURL {
        print("The device is showing a PIN. Waiting for it in \(pinFileURL.path)...")
        let deadline = Date().addingTimeInterval(pinWait)
        while Date() < deadline {
          if let text = try? String(contentsOf: pinFileURL, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
          }
          Thread.sleep(forTimeInterval: 0.5)
        }
        throw DevicePairError.pinRequired
      }
      print("Enter the PIN shown on the device: ", terminator: "")
      guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty else {
        throw DevicePairError.pinRequired
      }
      return line
    })
    print("Paired \(peer.name ?? peer.identifier).")
    var udid = peer.udid
    if udid == nil {
      print("Reading the device UDID over the paired tunnel...")
      udid = try pairer.resolveUDID(identifier: peer.identifier)
    }
    if let udid {
      print("UDID: \(udid)")
      print("Next: stupid-app signing setup --kind development --udid \(udid)")
      print("Then: stupid-app run --network --udid \(udid)")
    } else {
      print("The device did not report its UDID; remote identifier \(peer.identifier).")
    }
  }
}

enum DevicePairError: Error, CustomStringConvertible {
  case usbRequired
  case deviceSelection(Int)
  case networkDeviceSelection([String])
  case pinRequired

  var description: String {
    switch self {
    case .usbRequired:
      return "Select exactly one of --usb or --network."
    case .networkDeviceSelection(let names):
      return names.isEmpty
        ? "No device is waiting to pair. On the Apple TV open Settings > Remotes and Devices > Remote App and Devices, then retry (or pass --host and --port)."
        : "Several devices are waiting to pair (\(names.joined(separator: ", "))). Pass --host and --port."
    case .pinRequired:
      return "Network pairing needs the PIN shown on the device (--pin)."
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

struct DeviceContainerCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "container",
    abstract:
      "List or pull files from a development app's data container on a network-paired device."
  )

  @Option(name: .customLong("udid"), help: "UDID of a device paired for network use.")
  var udid: String

  @Option(name: .customLong("bundle-id"), help: "Bundle ID of the installed development app.")
  var bundleID: String

  @Option(name: .customLong("ls"), help: "Container directory to list, e.g. Library/Caches.")
  var listPath: String?

  @Option(name: .customLong("pull"), help: "Container file to read, e.g. Library/Caches/app.log.")
  var pullPath: String?

  @Option(name: .customLong("output"), help: "Write the pulled file here instead of stdout.")
  var output: String?

  @Option(name: .customLong("home"), help: "Credential store directory.")
  var home: String?

  mutating func run() throws {
    guard (listPath == nil) != (pullPath == nil) else {
      throw ValidationError("Pass exactly one of --ls or --pull.")
    }
    let homeURL =
      home.map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".stupid-app/credentials", isDirectory: true)
    let container = NetworkAppContainer(
      udid: udid, bundleID: bundleID,
      pairingDirectory: homeURL.appendingPathComponent("pairing", isDirectory: true))
    let data = try container.perform(
      listPath.map { .list($0) } ?? .read(pullPath ?? ""))
    if let output {
      try data.write(to: URL(fileURLWithPath: output))
      print("Wrote \(data.count) bytes to \(output)")
    } else {
      FileHandle.standardOutput.write(data)
      if listPath != nil { print("") }
    }
  }
}
