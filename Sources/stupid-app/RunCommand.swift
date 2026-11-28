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
    help: "Explicit path to sudo for USB CoreDevice operations (wireless runs need no sudo).")
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
    let os = config.resolvedPlatform
    if os == .tvos, usb || mac {
      throw RunError.unsupportedTVOSTransport
    }

    if simulator {
      return try runSimulator(projectRoot: projectRoot, config: config)
    }

    let credentialHome = credentialHomeURL()
    let pairingDirectory = credentialHome.appendingPathComponent("pairing", isDirectory: true)
    try validateTransportEnvironment(pairingDirectory: pairingDirectory)

    let context = try ASCContext.resolve(home: home, purpose: "run")

    // Resolve the development identity and team before any expensive work so a missing
    // profile or wrong target surfaces with an actionable message up front.
    let identity = try IdentityManager(store: context.credentialStore).loadDevelopment()
    guard let teamID = identity.teamID else {
      throw RunError.identityMissingTeam
    }

    let mode = HostSDKMode.detect()
    let platform = TargetPlatform(os: os, environment: .device)
    if os != .ios, case .importedBundle = mode {
      throw BuildError.platformRequiresXcode(os.displayName)
    }
    let toolchain = BuildToolchain.resolve(
      swiftPath: swiftPath,
      sdkID: sdkID,
      targetTriple: platform.targetTriple,
      mode: mode,
      platform: platform
    )
    let resolvedSwift = toolchain.swiftPath
    let planner = Planner(
      projectRoot: projectRoot, config: config, swiftPath: resolvedSwift,
      targetTriple: platform.targetTriple, platform: platform)
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
      targetTriple: platform.targetTriple,
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
      .appendingPathComponent(".build/\(platform.targetTriple)/debug", isDirectory: true)
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
      let networkRunner = NativeNetworkRunner(
        pairingDirectory: pairingDirectory,
        udid: targetUDID,
        ipa: ipaURL,
        bundleID: config.bundleID,
        progress: { print($0) }
      )
      let pid = try networkRunner.installAndLaunch()
      print("Installed and launched \(config.bundleID) (pid \(pid)).")
    }
  }

  func validateTransportEnvironment(pairingDirectory: URL) throws {
    guard usb else { return }
    let runner = NativeCoreDeviceRunner(
      sudoPath: sudoPath, pairingDirectory: pairingDirectory, usbmuxAddress: usbmuxAddress)
    try runner.validateEnvironment(requirePrivileges: true)
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
    let platform = TargetPlatform(os: config.resolvedPlatform, environment: .simulator)
    if platform.os != .ios, case .importedBundle = mode {
      throw BuildError.platformRequiresXcode(platform.os.displayName)
    }
    // Without Xcode the simulator is x86Sim's (Linux), built with the imported simulator
    // SDK; the device SDK's default identifier means the simulator one there.
    let isX86Sim: Bool
    if case .importedBundle = mode { isX86Sim = true } else { isX86Sim = false }
    let simulatorSDKID = isX86Sim && sdkID == "stupid-app-ios" ? "stupid-app-ios-simulator" : sdkID
    let toolchain = BuildToolchain.resolve(
      swiftPath: swiftPath,
      sdkID: simulatorSDKID,
      targetTriple: platform.targetTriple,
      mode: mode,
      platform: platform
    )
    let resolvedSwift = toolchain.swiftPath
    let planner = Planner(
      projectRoot: projectRoot,
      config: config,
      swiftPath: resolvedSwift,
      targetTriple: platform.targetTriple,
      platform: platform
    )
    let plan = try planner.makePlan()
    let packer = Packer(
      projectRoot: projectRoot,
      plan: plan,
      config: config,
      swiftPath: resolvedSwift,
      targetTriple: platform.targetTriple,
      sdkID: simulatorSDKID,
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
    if isX86Sim {
      try nativeAdHocSign(
        appURL: unsignedApp,
        entitlementsPath: config.entitlementsPath,
        extensionEntitlements: extensionEntitlements,
        projectRoot: projectRoot)
      let device = try X86Sim.selectDevice(udid)
      print("Using x86Sim device \(device.name) (\(device.udid))")
      if !device.booted {
        print("Booting \(device.name) and waiting for the home screen...")
        try X86Sim.boot(device)
      }
      print("Installing \(config.bundleID) on \(device.name)...")
      try X86Sim.install(device, appURL: unsignedApp)
      let launch = try X86Sim.launch(device, bundleID: config.bundleID)
      print("Launched \(config.bundleID) on x86Sim device \(device.name) (pid \(launch.pid)).")
      print("App output: \(launch.stdout.path)\n            \(launch.stderr.path)")
      try waitUntilInFront(
        device: device, bundleID: config.bundleID, appURL: unsignedApp, launch: launch)
      return
    }
    try adHocSign(
      appURL: unsignedApp,
      entitlementsPath: config.entitlementsPath,
      extensionEntitlements: extensionEntitlements,
      projectRoot: projectRoot)

    let device = try selectSimulatorDevice(udid: udid, os: platform.os)
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

  /// A launch is reported only once the app is in front. An app that crashes, or that
  /// never comes up, fails here with its output instead of leaving the home screen up and the
  /// command successful. stupid simulator (0.7.0 and later) fetches the runtime files an app
  /// opens on first use; one it could not fetch is a FAILED line in its fetch log, quoted here.
  private func waitUntilInFront(
    device: X86Sim.Device, bundleID: String, appURL: URL, launch: X86Sim.Launch
  ) throws {
    let info =
      (try? PropertyListSerialization.propertyList(
        from: Data(contentsOf: appURL.appendingPathComponent("Info.plist")), format: nil))
      as? [String: Any] ?? [:]
    let names = Set(
      [info["CFBundleDisplayName"], info["CFBundleName"], info["CFBundleExecutable"]]
        .compactMap { $0 as? String })
    guard X86Sim.hasStupidsim else {
      print(
        "stupidsim is not on PATH, so the launch is not checked; install stupid simulator to verify it."
      )
      return
    }
    let started = Date()
    var front: String?
    while Date().timeIntervalSince(started) < 90 {
      if !X86Sim.isRunning(device, bundleID: bundleID) {
        throw RunError.simulatorLaunchFailed(
          "\(bundleID) exited after launching.", outputTail(launch))
      }
      front = X86Sim.frontmostApplication(device)
      if let front, names.contains(front) {
        print("\(front) is on screen (\(Int(Date().timeIntervalSince(started))) s after launch).")
        return
      }
      Thread.sleep(forTimeInterval: 2)
    }
    var reason =
      "\(bundleID) is running but did not come to the front within 90 s (in front: \(front ?? "unknown"))."
    if let log = X86Sim.runtimeFetchLog(device) {
      let failed = X86Sim.failedFetches(
        inLog: (try? String(contentsOf: log, encoding: .utf8)) ?? "")
      reason +=
        failed.isEmpty
        ? " No runtime file failed to fetch (\(log.path)); the app's output is below."
        : " The simulator could not fetch runtime files (\(log.path)):\n"
          + failed.joined(separator: "\n")
    }
    throw RunError.simulatorLaunchFailed(reason, outputTail(launch))
  }

  private func outputTail(_ launch: X86Sim.Launch) -> String {
    [launch.stderr, launch.stdout].map { url -> String in
      let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(30)
      return "\(url.lastPathComponent):\n"
        + (text.isEmpty ? "  (empty)" : lines.joined(separator: "\n"))
    }.joined(separator: "\n")
  }

  /// The same ad-hoc pass without `/usr/bin/codesign` (Linux): SigningKit writes the
  /// signature `codesign -s -` makes, extensions first, then the app sealing them.
  private func nativeAdHocSign(
    appURL: URL,
    entitlementsPath: String?,
    extensionEntitlements: [String: String?],
    projectRoot: URL
  ) throws {
    func entitlements(_ path: String?) throws -> [String: Any] {
      guard let path else { return [:] }
      let url = URL(fileURLWithPath: path, relativeTo: projectRoot).standardizedFileURL
      let plist = try PropertyListSerialization.propertyList(
        from: try Data(contentsOf: url), options: [], format: nil)
      guard let dict = plist as? [String: Any] else {
        throw RunError.simulatorSigningFailed("\(path) is not an entitlements dictionary")
      }
      return SimulatorEntitlements.sanitize(dict)
    }
    let signer = NativeSigner()
    let pluginsDir = appURL.appendingPathComponent("PlugIns", isDirectory: true)
    let appexes =
      ((try? FileManager.default.contentsOfDirectory(atPath: pluginsDir.path)) ?? [])
      .filter { $0.hasSuffix(".appex") }.sorted()
    do {
      for appex in appexes {
        let product = (appex as NSString).deletingPathExtension
        try signer.adHocSign(
          appBundle: pluginsDir.appendingPathComponent(appex, isDirectory: true),
          entitlements: try entitlements(extensionEntitlements[product].flatMap { $0 }))
      }
      let frameworks = try EmbeddedFrameworks.adHocSign(in: appURL)
      try signer.adHocSign(
        appBundle: appURL, entitlements: try entitlements(entitlementsPath),
        mode: appexes.isEmpty && frameworks.isEmpty ? .shallow : .deep)
    } catch let error as RunError {
      throw error
    } catch {
      throw RunError.simulatorSigningFailed("\(error)")
    }
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

  private func selectSimulatorDevice(udid: String?, os: AppleOS) throws -> Simctl.Device {
    let runtimePrefix = "com.apple.CoreSimulator.SimRuntime.\(os.displayName)-"
    let devices = try Simctl.listDevices().filter {
      $0.runtimeIdentifier.hasPrefix(runtimePrefix)
    }
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
  case simulatorLaunchFailed(String, String)
  case simulatorNotFound(String)
  case noSimulatorDevice
  case localMacMismatch
  case unsupportedTVOSTransport

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
    case .simulatorLaunchFailed(let reason, let output):
      return "\(reason)\nThe app's output:\n\(output)"
    case .simulatorNotFound(let udid):
      return
        "No simulator device exists with UDID '\(udid)'. Run `stupid-app simulators` to list them."
    case .noSimulatorDevice:
      return
        "No simulator device is available. Install a runtime or run `stupid-app simulators` to list them."
    case .unsupportedTVOSTransport:
      return
        "tvOS apps deploy with --network (after `stupid-app device pair --network`) or --simulator; --usb and --mac are iOS-only."
    case .localMacMismatch:
      return "The supplied --udid does not identify this Mac. Omit --udid when using --mac."
    }
  }
}
