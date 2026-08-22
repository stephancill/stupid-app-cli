import ASCKit
import ArgumentParser
import BuildCore
import Foundation
import ProjectCore
import SDKCore
import SigningKit

/// `stupid-app release`: distribution build, signing, and upload operations.
struct ReleaseCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "release",
    abstract: "Distribution build, signing, and upload operations.",
    subcommands: [
      ReleaseArchiveCommand.self, ReleaseUploadCommand.self, ReleaseStatusCommand.self,
      ReleaseNewBuildCommand.self, ReleaseBumpCommand.self,
    ]
  )
}

/// `stupid-app release archive`: builds the app unsigned, derives and reconciles
/// distribution entitlements, embeds the App Store profile, signs once with the native
/// engine (timestamps disabled), packages the IPA, and verifies it.
struct ReleaseArchiveCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "archive",
    abstract: "Build, sign, and package a distribution IPA."
  )

  @Option(
    name: .customLong("sdk-id"), help: "Imported Swift SDK identifier (bundle hosts; default stupid-app-ios).")
  var sdkID: String = "stupid-app-ios"

  @Option(name: .customLong("swift"), help: "Path to the host `swift` executable.")
  var swiftPath: String = "swift"

  @Option(
    name: .customLong("sdk-version"), help: "Override the SDK version reported in LC_BUILD_VERSION."
  )
  var sdkVersionOverride: String?

  @Option(name: .customLong("home"), help: "Credential store directory.")
  var home: String?

  @Option(name: .customLong("output"), help: "Directory for the IPA (defaults to ./.release).")
  var output: String?

  mutating func run() async throws {
    let context = try ASCContext.resolve(home: home, purpose: "release archive")

    let configURL = URL(fileURLWithPath: "stupid-app.yml")
    guard let data = try? Data(contentsOf: configURL) else {
      throw ProjectError.unreadableConfig(configURL.path)
    }
    let config = try AppConfig.decode(data)
    let projectRoot = URL(fileURLWithPath: ".")

    // 1. Build the unsigned app (release configuration).
    let mode = HostSDKMode.detect()
    let toolchain = BuildToolchain.resolve(
      swiftPath: swiftPath,
      sdkID: sdkID,
      targetTriple: "arm64-apple-ios",
      mode: mode,
      sdkVersionOverride: sdkVersionOverride
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
      buildConfiguration: .release
    )
    let unsignedApp = try packer.pack()
    print("Assembled unsigned \(unsignedApp.path)")

    // 2. Load the distribution identity and App Store profile.
    let identity = try IdentityManager(store: context.credentialStore).loadDistribution()
    guard let teamID = identity.teamID else {
      throw ReleaseArchiveError.identityMissingTeam
    }
    let profileURL = try ProfileStore.requireFound(
      home: context.homeURL, kind: .distribution, bundleID: config.bundleID)

    // 3. Sign and package the IPA. Deep projects (with extensions) sign each nested
    // bundle first with its own profile, then the app in deep mode.
    let outputDir = URL(
      fileURLWithPath: output ?? projectRoot.appendingPathComponent(".release").path)
    if plan.extensions.isEmpty {
      let output = try SigningPipeline.signAndPackage(
        input: .init(
          unsignedApp: unsignedApp,
          identity: identity,
          teamID: teamID,
profileURL: profileURL,
          sourceEntitlementsURL: AppConfig.resolvedEntitlementsURL(
            entitlementsPath: config.entitlementsPath, projectRoot: projectRoot),
          configuration: .distribution,
          bundleID: config.bundleID,
          product: config.product,
          ipaOutputDirectory: outputDir
        ))
      print("Signed \(output.appBundle.path)")
      print("Packaged \(output.ipaURL.path)")
      print("IPA SHA-256: \(try SHA256.file(at: output.ipaURL))")
    } else {
      let extensions = try plan.extensions.map { extensionPlan -> DeepSigningPipeline.ExtensionInput in
        let appexURL = unsignedApp
          .appendingPathComponent("PlugIns/\(extensionPlan.product).appex", isDirectory: true)
        let extensionProfileURL = try ProfileStore.requireFound(
          home: context.homeURL, kind: .distribution, bundleID: extensionPlan.bundleID)
        return DeepSigningPipeline.ExtensionInput(
          appexBundle: appexURL,
          identity: identity,
          teamID: teamID,
          profileURL: extensionProfileURL,
          sourceEntitlementsURL: AppConfig.resolvedEntitlementsURL(
            entitlementsPath: extensionPlan.entitlementsPath, projectRoot: projectRoot),
          configuration: .distribution,
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
          configuration: .distribution,
          bundleID: config.bundleID,
          product: config.product,
          ipaOutputDirectory: outputDir
        ),
        extensions: extensions
      )
      print("Signed \(deepOutput.appBundle.path)")
      for result in deepOutput.extensions {
        print("Signed nested extension \(result.bundleID)")
      }
      print("Packaged \(deepOutput.ipaURL.path)")
      print("IPA SHA-256: \(try SHA256.file(at: deepOutput.ipaURL))")
    }

    print("Native signature passed the project-owned post-sign verifier.")
  }
}

enum ReleaseArchiveError: Error, CustomStringConvertible {
  case profileMissing(String)
  case identityMissingTeam

  var description: String {
    switch self {
    case .profileMissing(let bundleID):
      return
        "No App Store profile found for '\(bundleID)'. Run `stupid-app signing setup --kind distribution` first."
    case .identityMissingTeam:
      return
        "The stored distribution identity has no team ID. Re-run `stupid-app signing setup --kind distribution`."
    }
  }
}
