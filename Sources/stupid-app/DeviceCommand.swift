import ASCKit
import ArgumentParser
import DeviceKit
import Foundation

struct DeviceCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "device",
    abstract: "Manage local device pairing.",
    subcommands: [DevicePairCommand.self]
  )
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
    name: .customLong("python"),
    help: "Python 3.13 executable from the frozen pymobiledevice3 environment.")
  var pythonPath: String = "python3"

  @Option(
    name: .customLong("sudo"), help: "Explicit path to sudo for the privileged CoreDevice helper.")
  var sudoPath: String?

  @Option(
    name: .customLong("coredevice-helper"),
    help: "Root-owned installed CoreDevice helper path; defaults to the bundled helper.")
  var coreDeviceHelperPath: String?

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

    let runner = CoreDeviceRunner(
      pythonPath: pythonPath,
      sudoPath: sudoPath,
      helperPath: coreDeviceHelperPath,
      pairingDirectory: homeURL.appendingPathComponent("pairing", isDirectory: true),
      usbmuxAddress: usbmuxAddress,
      discoveryTimeoutSeconds: timeout
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
