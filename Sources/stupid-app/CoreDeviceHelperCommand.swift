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
    subcommands: [CoreDeviceLaunchCommand.self]
  )
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
