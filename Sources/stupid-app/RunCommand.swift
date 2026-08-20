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

  @Flag(
    name: .customLong("simulator"), help: "Build, install, and launch on a local simulator.")
  var simulator = false

  @Option(
    name: .customLong("udid"),
    help: "Target device or simulator UDID (auto-selected when omitted).")
  var udid: String?

  @Option(
    name: .customLong("sdk-id"),
    help: "Imported Swift SDK identifier (bundle hosts; default stupid-app-ios).")
  var sdkID: String = "stupid-app-ios"

  @Option(name: .customLong("swift"), help: "Path to the host `swift` executable.")
  var swiftPath: String = "swift"

  @Option(
    name: .customLong("sudo"),
    help: "Explicit path to sudo for the privileged CoreDevice helper.")
  var sudoPath: String?

  @Option(
    name: .customLong("usbmux"),
    help: "usbmuxd address (Unix socket or numeric HOST:PORT) used for USB operations.")
  var usbmuxAddress: String?

  @Option(name: .customLong("home"), help: "Credential store directory.")
  var home: String?

  mutating func run() async throws {
    let transports = [usb, network, simulator].filter { $0 }.count
    guard transports == 1 else {
      throw RunError.unsupportedTransport
    }
    if network, udid == nil {
      throw RunError.networkDeviceRequired
    }

    let configURL = URL(fileURLWithPath: "stupid-app.yml")
    guard let data = try? Data(contentsOf: configURL) else {
      throw ProjectError.unreadableConfig(configURL.path)
    }
    let config = try AppConfig.decode(data)
    let projectRoot = URL(fileURLWithPath: ".")

    if simulator {
      return try runSimulator(projectRoot: projectRoot, config: config)
    }

    let credentialHome = credentialHomeURL()
    let pairingDirectory = credentialHome.appendingPathComponent("pairing", isDirectory: true)
    let nativeRunner = NativeCoreDeviceRunner(
      sudoPath: sudoPath,
      pairingDirectory: pairingDirectory,
      usbmuxAddress: usbmuxAddress
    )
    try nativeRunner.validateEnvironment(requirePrivileges: true)

    let context = try ASCContext.resolve(home: home, purpose: "run")

    // 1. Build the unsigned app (debug configuration).
    let mode = HostSDKMode.detect()
    let toolchain = BuildToolchain.resolve(
      swiftPath: swiftPath,
      sdkID: sdkID,
      targetTriple: TargetPlatform.device.targetTriple,
      mode: mode
    )
    let resolvedSwift = toolchain.swiftPath
    let planner = Planner(projectRoot: projectRoot, config: config, swiftPath: resolvedSwift)
    let plan = try planner.makePlan()
    if case .importedBundle = toolchain.sdkInput {
      guard SDKVersion.isInstalled(sdkID: sdkID, swiftPath: resolvedSwift) else {
        throw SDKVersion.Error.sdkNotInstalled(sdkID)
      }
    }
    let packer = Packer(
      projectRoot: projectRoot,
      plan: plan,
      config: config,
      swiftPath: resolvedSwift,
      sdkID: sdkID,
      sdkInput: toolchain.sdkInput,
      sdkVersion: toolchain.hostSDKVersion,
      buildConfiguration: .debug
    )
    let unsignedApp = try packer.pack()
    print("Assembled unsigned \(unsignedApp.path)")

    // 2. Load the development identity and device development profile.
    let identity = try IdentityManager(store: context.credentialStore).loadDevelopment()
    guard let teamID = identity.teamID else {
      throw RunError.identityMissingTeam
    }
    guard let profileURL = try locateProfile(home: context.homeURL, bundleID: config.bundleID)
    else {
      throw RunError.profileMissing(config.bundleID)
    }

    // 3. Sign with development entitlements and package the IPA. Deep projects sign
    // each nested extension first, then the app in deep mode.
    let ipaDir =
      projectRoot
      .appendingPathComponent(".build/arm64-apple-ios/debug", isDirectory: true)
    var ipaURL: URL
    if plan.extensions.isEmpty {
      let output = try SigningPipeline.signAndPackage(
        input: .init(
          unsignedApp: unsignedApp,
          identity: identity,
          teamID: teamID,
          profileURL: profileURL,
          sourceEntitlementsURL: AppConfig.resolvedEntitlementsURL(
            entitlementsPath: config.entitlementsPath, projectRoot: projectRoot),
          configuration: .development,
          bundleID: config.bundleID,
          product: config.product,
          ipaOutputDirectory: ipaDir
        ))
      ipaURL = output.ipaURL
      print("Signed \(output.appBundle.path)")
      print("Packaged \(output.ipaURL.path)")
      print("IPA SHA-256: \(try SHA256.file(at: output.ipaURL))")
    } else {
      let extensions = try plan.extensions.map {
        extensionPlan -> DeepSigningPipeline.ExtensionInput in
        let appexURL =
          unsignedApp
          .appendingPathComponent("PlugIns/\(extensionPlan.product).appex", isDirectory: true)
        guard
          let extensionProfileURL = try locateProfile(
            home: context.homeURL, bundleID: extensionPlan.bundleID)
        else {
          throw RunError.profileMissing(extensionPlan.bundleID)
        }
        return DeepSigningPipeline.ExtensionInput(
          appexBundle: appexURL,
          identity: identity,
          teamID: teamID,
          profileURL: extensionProfileURL,
          sourceEntitlementsURL: AppConfig.resolvedEntitlementsURL(
            entitlementsPath: extensionPlan.entitlementsPath, projectRoot: projectRoot),
          configuration: .development,
          bundleID: extensionPlan.bundleID
        )
      }
      let deepOutput = try DeepSigningPipeline.signAndPackage(
        input: .init(
          unsignedApp: unsignedApp,
          identity: identity,
          teamID: teamID,
          profileURL: profileURL,
          sourceEntitlementsURL: AppConfig.resolvedEntitlementsURL(
            entitlementsPath: config.entitlementsPath, projectRoot: projectRoot),
          configuration: .development,
          bundleID: config.bundleID,
          product: config.product,
          ipaOutputDirectory: ipaDir
        ),
        extensions: extensions
      )
      ipaURL = deepOutput.ipaURL
      print("Signed \(deepOutput.appBundle.path)")
      for result in deepOutput.extensions { print("Signed nested extension \(result.bundleID)") }
      print("Packaged \(deepOutput.ipaURL.path)")
      print("IPA SHA-256: \(try SHA256.file(at: deepOutput.ipaURL))")
    }

    // 4. Determine the target device.
    if usb {
      let discovery = USBMuxClient(address: usbmuxAddress)
      let installer = NativeUSBInstaller(
        usbmuxAddress: usbmuxAddress,
        pairingDirectory: credentialHome.appendingPathComponent("pairing", isDirectory: true),
        progress: { print($0) }
      )
      guard let targetUDID = try resolveTargetUDID(discovery: discovery) else {
        throw RunError.deviceSelection(0)
      }
      print("Installing on the selected device over USB...")
      try installer.install(ipa: ipaURL, bundleID: config.bundleID, udid: targetUDID)
      print("Installed.")
      let nativeRunner = NativeCoreDeviceRunner(
        sudoPath: sudoPath,
        pairingDirectory: credentialHome.appendingPathComponent("pairing", isDirectory: true),
        usbmuxAddress: usbmuxAddress
      )
      let pid = try nativeRunner.launchUSB(bundleID: config.bundleID, udid: targetUDID)
      print("Launched \(config.bundleID) (pid \(pid)).")
    } else if let udid {
      #if os(macOS)
        // macOS utun creation requires root; the network path owns the TUN
        // inside the privileged helper through the same explicit --sudo boundary
        // as the USB launch.
        print("Installing and launching on the selected device over the network...")
        let pid = try nativeRunner.runNetwork(
          bundleID: config.bundleID,
          udid: udid,
          ipa: ipaURL
        )
        print("Installed and launched \(config.bundleID) (pid \(pid)).")
      #else
        let networkRunner = NativeNetworkRunner(
          pairingDirectory: credentialHome.appendingPathComponent("pairing", isDirectory: true),
          udid: udid,
          ipa: ipaURL,
          bundleID: config.bundleID,
          progress: { print($0) }
        )
        print("Installing and launching on the selected device over the network...")
        let pid = try networkRunner.installAndLaunch()
        print("Installed and launched \(config.bundleID) (pid \(pid)).")
      #endif
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

  private func runSimulator(projectRoot: URL, config: AppConfig) throws {
    let mode = HostSDKMode.detect()
    guard case .xcodeInPlace = mode else {
      throw BuildError.simulatorRequiresXcode
    }
    let toolchain = BuildToolchain.resolve(
      swiftPath: swiftPath,
      sdkID: sdkID,
      targetTriple: TargetPlatform.simulator.targetTriple,
      mode: mode,
      platform: .simulator
    )
    let resolvedSwift = toolchain.swiftPath
    let planner = Planner(
      projectRoot: projectRoot,
      config: config,
      swiftPath: resolvedSwift,
      targetTriple: TargetPlatform.simulator.targetTriple,
      platform: .simulator
    )
    let plan = try planner.makePlan()
    let packer = Packer(
      projectRoot: projectRoot,
      plan: plan,
      config: config,
      swiftPath: resolvedSwift,
      targetTriple: TargetPlatform.simulator.targetTriple,
      sdkID: sdkID,
      sdkInput: toolchain.sdkInput,
      sdkVersion: toolchain.hostSDKVersion,
      buildConfiguration: .debug
    )
    let unsignedApp = try packer.pack()
    print("Assembled unsigned \(unsignedApp.path)")

    // Ad-hoc signing is the scoped simulator exception: it is the normal, required
    // mode for simulator execution and is never an intermediate pass in a device or
    // release pipeline. Simulator .app output is never a device or release artifact.
    print("Ad-hoc signing for the simulator (scoped exception: never a device/release artifact)...")
    try adHocSign(appURL: unsignedApp)

    let device = try selectSimulatorDevice(udid: udid)
    print("Using simulator \(device.name) (\(device.udid))")

    let state = device.state.lowercased()
    if state.contains("shutdown") || state.contains("created") {
      print("Booting simulator \(device.udid)...")
      try Simctl.boot(udid: device.udid)
      try Simctl.bootStatus(udid: device.udid)
    }

    print("Installing \(config.bundleID) on \(device.udid)...")
    try Simctl.install(udid: device.udid, appURL: unsignedApp)
    let pid = try Simctl.launch(udid: device.udid, bundleID: config.bundleID)
    print("Launched \(config.bundleID) on simulator \(device.name) (pid \(pid)).")
  }

  private func adHocSign(appURL: URL) throws {
    // `codesign -s -` performs the ad-hoc signing that Xcode's "Sign to Run Locally"
    // uses for simulator builds. The scoped exception is documented in
    // docs/macos-host-support-scope.md. For deep apps (with bundled extensions), each
    // nested .appex is ad-hoc signed leaf-first so the simulator can load the widget
    // extension, then the containing app seals the signed appex.
    let pluginsDir = appURL.appendingPathComponent("PlugIns", isDirectory: true)
    if FileManager.default.fileExists(atPath: pluginsDir.path),
      let appexes = try? FileManager.default.contentsOfDirectory(atPath: pluginsDir.path)
    {
      for appex in appexes.sorted()
      where appex.hasSuffix(".appex") {
        try adHocSignSingle(
          appURL: pluginsDir.appendingPathComponent(appex, isDirectory: true))
      }
    }
    try adHocSignSingle(appURL: appURL)
  }

  private func adHocSignSingle(appURL: URL) throws {
    let result = try ProcessRunner.run(
      executable: "/usr/bin/codesign",
      arguments: ["--force", "--sign", "-", appURL.path]
    )
    guard result.succeeded else {
      let detail = result.stderr.isEmpty ? result.stdout : result.stderr
      throw RunError.simulatorSigningFailed(detail)
    }
  }

  private func selectSimulatorDevice(udid: String?) throws -> Simctl.Device {
    let devices = try Simctl.listDevices()
    if let udid {
      guard let device = devices.first(where: { $0.udid == udid }) else {
        throw RunError.simulatorNotFound(udid)
      }
      return device
    }
    // Prefer a booted device; otherwise the first device of the newest runtime.
    if let booted = devices.first(where: { $0.state.lowercased() == "booted" }) {
      return booted
    }
    guard let first = devices.first else {
      throw RunError.noSimulatorDevice
    }
    return first
  }

  private func credentialHomeURL() -> URL {
    if let home {
      return URL(fileURLWithPath: home)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".stupid-app/credentials", isDirectory: true)
  }

  private func locateProfile(home: URL, bundleID: String) throws -> URL? {
    let candidates = [
      home.appendingPathComponent("profiles/\(bundleID) Development.mobileprovision"),
      home.appendingPathComponent("profiles/\(bundleID).mobileprovision"),
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
      return url
    }
    return nil
  }
}

enum RunError: Error, CustomStringConvertible {
  case unsupportedTransport
  case identityMissingTeam
  case profileMissing(String)
  case deviceSelection(Int)
  case networkDeviceRequired
  case simulatorSigningFailed(String)
  case simulatorNotFound(String)
  case noSimulatorDevice

  var description: String {
    switch self {
    case .unsupportedTransport:
      return "Select exactly one deployment transport: --usb, --network, or --simulator."
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
    case .simulatorSigningFailed(let detail):
      return "Ad-hoc simulator signing failed. \(detail)"
    case .simulatorNotFound(let udid):
      return
        "No simulator device exists with UDID '\(udid)'. Run `stupid-app simulators` to list them."
    case .noSimulatorDevice:
      return
        "No simulator device is available. Install a runtime or run `stupid-app simulators` to list them."
    }
  }
}
