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
    name: .customLong("network"),
    help: "Install and launch through a CoreDevice network tunnel.")
  var network = false

  @Flag(
    name: .customLong("simulator"), help: "Build, install, and launch on a local simulator.")
  var simulator = false

  @Flag(
    name: .customLong("mac"),
    help: "Build, install, and launch as an iPhone/iPad app on this Apple Silicon Mac.")
  var mac = false

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
    let transports = [usb, network, simulator, mac].filter { $0 }.count
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
    let nativeRunner: NativeCoreDeviceRunner?
    if mac {
      nativeRunner = nil
    } else {
      let runner = NativeCoreDeviceRunner(
        sudoPath: sudoPath,
        pairingDirectory: pairingDirectory,
        usbmuxAddress: usbmuxAddress
      )
      try runner.validateEnvironment(requirePrivileges: true)
      nativeRunner = runner
    }

    let context = try ASCContext.resolve(home: home, purpose: "run")

    // Resolve the development identity and team before any expensive work so a missing
    // profile or wrong target surfaces with an actionable message up front.
    let identity = try IdentityManager(store: context.credentialStore).loadDevelopment()
    guard let teamID = identity.teamID else {
      throw RunError.identityMissingTeam
    }

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

    // Locate every development profile before building so a stale or missing profile is
    // caught before the expensive SwiftPM build.
    let appProfileURL = try ProfileStore.requireFound(
      home: context.homeURL, kind: .development, bundleID: config.bundleID)
    var extensionProfileURLs: [String: URL] = [:]
    for extensionPlan in plan.extensions {
      extensionProfileURLs[extensionPlan.bundleID] = try ProfileStore.requireFound(
        home: context.homeURL, kind: .development, bundleID: extensionPlan.bundleID)
    }

    // Resolve the target device before building and preflight the profiles against it.
    let targetUDID: String
    if mac {
      let device = try MacCompatibilityRunner.localDevice()
      if let udid, udid != device.identifier {
        throw RunError.localMacMismatch
      }
      targetUDID = device.identifier
      print("Using \(device.name) as an iPhone/iPad compatibility destination.")
    } else if usb {
      let discovery = USBMuxClient(address: usbmuxAddress)
      guard let resolved = try resolveTargetUDID(discovery: discovery) else {
        throw RunError.deviceSelection(0)
      }
      targetUDID = resolved
    } else if let udid {
      targetUDID = udid
    } else {
      throw RunError.networkDeviceRequired
    }

    let appProfile = try MobileProvisionParser.parse(at: appProfileURL)
    try ProfilePreflight.validate(
      appProfile, kind: .development, teamID: teamID, bundleID: config.bundleID,
      deviceUDID: targetUDID)
    for (bundleID, url) in extensionProfileURLs {
      let extensionProfile = try MobileProvisionParser.parse(at: url)
      try ProfilePreflight.validate(
        extensionProfile, kind: .development, teamID: teamID,
        bundleID: bundleID, deviceUDID: targetUDID)
    }

    // 1. Build the unsigned app (debug configuration).
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

    // 2. Sign with development entitlements and package the IPA. Deep projects sign
    // each nested extension first, then the app in deep mode.
    let ipaDir =
      projectRoot
      .appendingPathComponent(".build/arm64-apple-ios/debug", isDirectory: true)
    var ipaURL: URL
    var signedAppURL: URL
    if plan.extensions.isEmpty {
      let output = try SigningPipeline.signAndPackage(
        input: .init(
          unsignedApp: unsignedApp,
          identity: identity,
          teamID: teamID,
          profileURL: appProfileURL,
          sourceEntitlementsURL: AppConfig.resolvedEntitlementsURL(
            entitlementsPath: config.entitlementsPath, projectRoot: projectRoot),
          configuration: .development,
          bundleID: config.bundleID,
          product: config.product,
          ipaOutputDirectory: ipaDir
        ))
      ipaURL = output.ipaURL
      signedAppURL = output.appBundle
      print("Signed \(output.appBundle.path)")
      print("Packaged \(output.ipaURL.path)")
      print("IPA SHA-256: \(try SHA256.file(at: output.ipaURL))")
    } else {
      let extensions = try plan.extensions.map {
        extensionPlan -> DeepSigningPipeline.ExtensionInput in
        let appexURL =
          unsignedApp
          .appendingPathComponent(
            "PlugIns/\(extensionPlan.product).appex", isDirectory: true)
        guard let extensionProfileURL = extensionProfileURLs[extensionPlan.bundleID] else {
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
          profileURL: appProfileURL,
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
      signedAppURL = deepOutput.appBundle
      print("Signed \(deepOutput.appBundle.path)")
      for result in deepOutput.extensions {
        print("Signed nested extension \(result.bundleID)")
      }
      print("Packaged \(deepOutput.ipaURL.path)")
      print("IPA SHA-256: \(try SHA256.file(at: deepOutput.ipaURL))")
    }

    // 3. Install and launch on the selected target.
    if mac {
      print(
        "Installing \(config.bundleID) in this Mac's iPhone/iPad compatibility environment..."
      )
      let installedURL = try MacCompatibilityRunner.installAndLaunch(appURL: signedAppURL)
      print("Installed and launched \(config.bundleID) at \(installedURL.path).")
    } else if usb {
      print("Installing \(config.bundleID) on the selected device over USB...")
      let installer = NativeUSBInstaller(
        usbmuxAddress: usbmuxAddress,
        pairingDirectory: pairingDirectory,
        progress: { print($0) }
      )
      try installer.install(ipa: ipaURL, bundleID: config.bundleID, udid: targetUDID)
      print("Installed.")
      let launcher = NativeCoreDeviceRunner(
        sudoPath: sudoPath,
        pairingDirectory: pairingDirectory,
        usbmuxAddress: usbmuxAddress
      )
      let pid = try launcher.launchUSB(bundleID: config.bundleID, udid: targetUDID)
      print("Launched \(config.bundleID) (pid \(pid)).")
    } else {
      print(
        "Installing and launching \(config.bundleID) on the selected device over the network..."
      )
      #if os(macOS)
        guard let nativeRunner else { throw RunError.unsupportedTransport }
        let pid = try nativeRunner.runNetwork(
          bundleID: config.bundleID,
          udid: targetUDID,
          ipa: ipaURL
        )
        print("Installed and launched \(config.bundleID) (pid \(pid)).")
      #else
        let networkRunner = NativeNetworkRunner(
          pairingDirectory: pairingDirectory,
          udid: targetUDID,
          ipa: ipaURL,
          bundleID: config.bundleID,
          progress: { print($0) }
        )
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
    print(
      "Ad-hoc signing for the simulator (scoped exception: never a device/release artifact)..."
    )
    let extensionEntitlements: [String: String?] = plan.extensions.reduce(into: [:]) {
      $0[$1.product] = $1.entitlementsPath
    }
    try adHocSign(
      appURL: unsignedApp,
      entitlementsPath: config.entitlementsPath,
      extensionEntitlements: extensionEntitlements,
      projectRoot: projectRoot)

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

  private func adHocSign(
    appURL: URL,
    entitlementsPath: String?,
    extensionEntitlements: [String: String?],
    projectRoot: URL
  ) throws {
    // `codesign -s -` performs the ad-hoc signing that Xcode's "Sign to Run Locally"
    // uses for simulator builds. The scoped exception is documented in
    // docs/macos-host-support-scope.md. For deep apps (with bundled extensions), each
    // nested .appex is ad-hoc signed leaf-first so the simulator can load the widget
    // extension, then the containing app seals the signed appex.
    // Project entitlements are sanitized during this ad-hoc pass. App Groups are kept so
    // shared containers work on the simulator; team- and profile-gated entitlements are
    // removed because an ad-hoc signature cannot satisfy them.
    let pluginsDir = appURL.appendingPathComponent("PlugIns", isDirectory: true)
    if FileManager.default.fileExists(atPath: pluginsDir.path),
      let appexes = try? FileManager.default.contentsOfDirectory(atPath: pluginsDir.path)
    {
      for appex in appexes.sorted()
      where appex.hasSuffix(".appex") {
        let product = (appex as NSString).deletingPathExtension
        let extEnts = extensionEntitlements[product].flatMap { $0 }
        try adHocSignSingle(
          appURL: pluginsDir.appendingPathComponent(appex, isDirectory: true),
          entitlementsPath: extEnts,
          projectRoot: projectRoot)
      }
    }
    try adHocSignSingle(
      appURL: appURL,
      entitlementsPath: entitlementsPath,
      projectRoot: projectRoot)
  }

  private func adHocSignSingle(
    appURL: URL, entitlementsPath: String?, projectRoot: URL
  ) throws {
    var arguments = ["--force", "--sign", "-"]
    if let entitlementsPath {
      let original = URL(
        fileURLWithPath: entitlementsPath, relativeTo: projectRoot
      ).standardizedFileURL.path
      // Ad-hoc simulator signing has no team/AppIdentifierPrefix value. Materialize the
      // entitlements into a concrete override with `$(AppIdentifierPrefix)` removed so the
      // keychain/App Group groups are usable on the simulator.
      let simEntitlements = try substituteAppIdentifierPrefix(in: original)
      arguments += ["--entitlements", simEntitlements]
    }
    arguments.append(appURL.path)
    let result = try ProcessRunner.run(
      executable: "/usr/bin/codesign",
      arguments: arguments
    )
    guard result.succeeded else {
      let detail = result.stderr.isEmpty ? result.stdout : result.stderr
      throw RunError.simulatorSigningFailed(detail)
    }
  }

  /// Returns a concrete entitlements override for ad-hoc (team-less) simulator signing.
  /// The bare `$(AppIdentifierPrefix)` is removed and the whole `keychain-access-groups`
  /// dictionary is dropped, because the simulator has no team/app-id prefix and a
  /// team-less keychain group makes SpringBoard reject the launch, while the simulator's
  /// default keychain group is the app bundle-id. Profile-gated capabilities (for example
  /// `autofill-credential-provider`) are also dropped: an ad-hoc signature cannot satisfy
  /// them, and embedding them makes SpringBoard reject the launch with "Security policy
  /// issue". `com.apple.security.application-groups` (used for the shared container) is
  /// preserved. The original file is untouched.
  private func substituteAppIdentifierPrefix(in sourcePath: String) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: sourcePath))
    let plist = try PropertyListSerialization.propertyList(
      from: data, options: [], format: nil)
    guard var dict = plist as? [String: Any] else { return sourcePath }
    dict = SimulatorEntitlements.sanitize(dict)

    let override = try PropertyListSerialization.data(
      fromPropertyList: dict, format: .xml, options: 0)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".entitlements")
    try override.write(to: url)
    return url.path
  }

  /// Entitlement sanitization for ad-hoc (team-less) simulator signing. `stupid-app`
  /// preserves this override logic in one place so release signing always uses the
  /// source entitlements while simulator builds get a relaxed, launchable subset.
  enum SimulatorEntitlements {
    static func sanitize(_ source: [String: Any]) -> [String: Any] {
      var dict = source
      // The simulator has no team/app-id prefix, so `keychain-access-groups` cannot be
      // expressed and a team-less keychain group makes SpringBoard reject the launch.
      dict["keychain-access-groups"] = nil
      // Entitlements granted by provisioning profiles cannot be satisfied by an ad-hoc
      // signature; embedding them makes SpringBoard reject the launch with "Security
      // policy issue" (launchd POSIX 163). Capability enablement is intentionally open-
      // ended, so this must cover the developer entitlement namespace rather than list
      // individual capabilities such as AutoFill, Push, Siri, or Communication Notifications.
      let profileGatedKeys = dict.keys.filter {
        $0 == "application-identifier" || $0 == "aps-environment"
          || $0.hasPrefix("com.apple.developer.")
      }
      for key in profileGatedKeys {
        dict[key] = nil
      }
      // The shared-container App Group is preserved, with any `$(AppIdentifierPrefix)`
      // token removed because there is no team prefix on the simulator.
      if let groups = dict["com.apple.security.application-groups"] as? [String] {
        dict["com.apple.security.application-groups"] =
          groups.map { $0.replacingOccurrences(of: "$(AppIdentifierPrefix)", with: "") }
      }
      return dict
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
  case localMacMismatch

  var description: String {
    switch self {
    case .unsupportedTransport:
      return
        "Select exactly one deployment transport: --usb, --network, --simulator, or --mac."
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
    case .localMacMismatch:
      return "The supplied --udid does not identify this Mac. Omit --udid when using --mac."
    }
  }
}
