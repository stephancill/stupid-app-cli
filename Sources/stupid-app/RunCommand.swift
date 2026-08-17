import ASCKit
import ArgumentParser
import BuildCore
import DeviceKit
import Foundation
import ProjectCore
import SDKCore
import SigningKit

/// `stupid-app run`: build, sign, install, and launch the app on a physical device.
/// USB and wireless deployment share the same one-pass development signing pipeline.
struct RunCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Build, sign, install, and launch the app on a device."
  )

  @Flag(name: .customLong("usb"), help: "Install and launch over USB.")
  var usb = false

  @Flag(
    name: .customLong("network"), help: "Install and launch through a CoreDevice network tunnel.")
  var network = false

  @Option(
    name: .customLong("udid"),
    help: "Target device UDID (auto-detected when omitted with one USB device).")
  var udid: String?

  @Option(
    name: .customLong("sdk-id"), help: "Imported Swift SDK identifier (default stupid-app-ios).")
  var sdkID: String = "stupid-app-ios"

  @Option(name: .customLong("swift"), help: "Path to the host `swift` executable.")
  var swiftPath: String = "swift"

  @Option(
    name: .customLong("python"),
    help: "Python 3.13 executable from the frozen pymobiledevice3 environment.")
  var pythonPath: String = "python3"

  @Option(
    name: .customLong("sudo"),
    help: "Explicit path to sudo for the privileged CoreDevice helper.")
  var sudoPath: String?

  @Option(
    name: .customLong("coredevice-helper"),
    help: "Root-owned installed CoreDevice helper path; defaults to the bundled helper.")
  var coreDeviceHelperPath: String?

  @Option(
    name: .customLong("usbmux"),
    help: "usbmuxd address (Unix socket or numeric HOST:PORT) used for USB operations.")
  var usbmuxAddress: String?

  @Option(
    name: .customLong("install-timeout"), help: "Maximum seconds allowed for installation.")
  var installTimeout: Double = 300

  @Option(name: .customLong("launch-timeout"), help: "Maximum seconds allowed for app launch.")
  var launchTimeout: Double = 60

  @Option(name: .customLong("home"), help: "Credential store directory.")
  var home: String?

  mutating func run() async throws {
    guard usb != network else {
      throw RunError.unsupportedTransport
    }
    if network, udid == nil {
      throw RunError.networkDeviceRequired
    }

    let credentialHome = credentialHomeURL()
    let pairingDirectory = credentialHome.appendingPathComponent("pairing", isDirectory: true)
    let coreDevice = CoreDeviceRunner(
      pythonPath: pythonPath,
      sudoPath: sudoPath,
      helperPath: coreDeviceHelperPath,
      pairingDirectory: pairingDirectory,
      usbmuxAddress: usbmuxAddress,
      installTimeoutSeconds: installTimeout,
      launchTimeoutSeconds: launchTimeout
    )
    if usb {
      let nativeRunner = NativeCoreDeviceRunner(
        sudoPath: sudoPath,
        pairingDirectory: pairingDirectory,
        usbmuxAddress: usbmuxAddress,
        launchTimeoutSeconds: launchTimeout
      )
      try nativeRunner.validateEnvironment(requirePrivileges: true)
    } else {
      try coreDevice.validateEnvironment(requirePrivileges: true)
    }

    let context = try ASCContext.resolve(home: home, purpose: "run")

    let configURL = URL(fileURLWithPath: "stupid-app.yml")
    guard let data = try? Data(contentsOf: configURL) else {
      throw ProjectError.unreadableConfig(configURL.path)
    }
    let config = try AppConfig.decode(data)
    let projectRoot = URL(fileURLWithPath: ".")

    // 1. Build the unsigned app (debug configuration).
    let planner = Planner(projectRoot: projectRoot, config: config, swiftPath: swiftPath)
    let plan = try planner.makePlan()
    guard SDKVersion.isInstalled(sdkID: sdkID, swiftPath: swiftPath) else {
      throw SDKVersion.Error.sdkNotInstalled(sdkID)
    }
    let packer = Packer(
      projectRoot: projectRoot,
      plan: plan,
      config: config,
      swiftPath: swiftPath,
      sdkID: sdkID,
      buildConfiguration: .debug
    )
    let unsignedApp = try packer.pack()
    print("Assembled unsigned \(unsignedApp.path)")

    // 2. Load the development identity and device development profile.
    let identity = try IdentityManager(store: context.credentialStore).loadDevelopment()
    guard let teamID = identity.teamID else {
      throw RunError.identityMissingTeam
    }
    let profileURL = try locateProfile(home: context.homeURL, bundleID: config.bundleID)

    // 3. Sign once with development entitlements and package the IPA.
    let ipaDir =
      projectRoot
      .appendingPathComponent(".build/arm64-apple-ios/debug", isDirectory: true)
    let output = try SigningPipeline.signAndPackage(
      input: .init(
        unsignedApp: unsignedApp,
        identity: identity,
        teamID: teamID,
        profileURL: profileURL,
        sourceEntitlementsURL: projectRoot.appendingPathComponent(
          config.entitlementsPath ?? "App.entitlements"),
        configuration: .development,
        bundleID: config.bundleID,
        product: config.product,
        ipaOutputDirectory: ipaDir
      ))
    print("Signed \(output.appBundle.path)")
    print("Packaged \(output.ipaURL.path)")
    print("IPA SHA-256: \(try SHA256.file(at: output.ipaURL))")

    // 4. Determine the target device.
    if usb {
      let discovery = USBMuxClient(address: usbmuxAddress)
      let installer = NativeUSBInstaller(
        usbmuxAddress: usbmuxAddress,
        pairingDirectory: credentialHome.appendingPathComponent("pairing", isDirectory: true),
        timeoutSeconds: installTimeout,
        progress: { print($0) }
      )
      guard let targetUDID = try resolveTargetUDID(discovery: discovery) else {
        throw RunError.deviceSelection(0)
      }
      print("Installing on the selected device over USB...")
      try installer.install(ipa: output.ipaURL, bundleID: config.bundleID, udid: targetUDID)
      print("Installed.")
      let nativeRunner = NativeCoreDeviceRunner(
        sudoPath: sudoPath,
        pairingDirectory: credentialHome.appendingPathComponent("pairing", isDirectory: true),
        usbmuxAddress: usbmuxAddress,
        launchTimeoutSeconds: launchTimeout
      )
      let pid = try nativeRunner.launchUSB(bundleID: config.bundleID, udid: targetUDID)
      print("Launched \(config.bundleID) (pid \(pid)).")
    } else if let udid {
      print("Installing and launching on the selected device over the network...")
      try coreDevice.installAndLaunchNetwork(
        ipa: output.ipaURL,
        bundleID: config.bundleID,
        udid: udid
      )
      print("Installed and launched \(config.bundleID).")
    }
  }

  private func resolveTargetUDID(discovery: any USBDeviceDiscovering) throws -> String? {
    if let udid {
      return udid
    }
    let devices = try discovery.usbDeviceUDIDs()
    guard devices.count == 1 else {
      throw RunError.deviceSelection(devices.count)
    }
    print("Using the sole USB-connected device.")
    return devices[0]
  }

  private func credentialHomeURL() -> URL {
    if let home {
      return URL(fileURLWithPath: home)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".stupid-app/credentials", isDirectory: true)
  }

  private func locateProfile(home: URL, bundleID: String) throws -> URL {
    let candidates = [
      home.appendingPathComponent("profiles/\(bundleID) Development.mobileprovision"),
      home.appendingPathComponent("profiles/\(bundleID).mobileprovision"),
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
      return url
    }
    throw RunError.profileMissing(bundleID)
  }
}

enum RunError: Error, CustomStringConvertible {
  case unsupportedTransport
  case identityMissingTeam
  case profileMissing(String)
  case deviceSelection(Int)
  case networkDeviceRequired

  var description: String {
    switch self {
    case .unsupportedTransport:
      return "Select exactly one deployment transport: --usb or --network."
    case .identityMissingTeam:
      return
        "The stored development identity has no team ID. Re-run `stupid-app signing setup --kind development`."
    case .profileMissing(let bundleID):
      return
        "No development profile found for '\(bundleID)'. Run `stupid-app signing setup --kind development --bundle-id <id> --udid <udid>` first."
    case .deviceSelection(let count):
      return
        "Expected exactly one USB-connected device, found \(count). Pass --udid to select a device."
    case .networkDeviceRequired:
      return
        "Network deployment requires --udid because remote pairing identifiers are not device UDIDs."
    }
  }
}
