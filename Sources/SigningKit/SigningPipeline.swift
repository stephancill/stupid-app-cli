import BuildCore
import Foundation
import ProjectCore

/// The shared post-build signing and packaging pipeline used by both distribution
/// (`release archive`) and development (`run`) flows. Keeps entitlement derivation,
/// profile embedding, the one real signing pass, and IPA packaging as a single
/// independently testable boundary with explicit inputs.
public enum SigningPipeline {
  public struct Input: Sendable {
    /// Unsigned `.app` bundle produced by `Packer`.
    public var unsignedApp: URL
    public var identity: IdentityManager.SigningIdentity
    public var teamID: String
    public var profileURL: URL
    /// Source `App.entitlements` plist.
    public var sourceEntitlementsURL: URL
    public var configuration: EntitlementDeriver.Configuration
    public var bundleID: String
    /// App product name used for the IPA filename.
    public var product: String
    public var ipaOutputDirectory: URL

    public init(
      unsignedApp: URL,
      identity: IdentityManager.SigningIdentity,
      teamID: String,
      profileURL: URL,
      sourceEntitlementsURL: URL,
      configuration: EntitlementDeriver.Configuration,
      bundleID: String,
      product: String,
      ipaOutputDirectory: URL
    ) {
      self.unsignedApp = unsignedApp
      self.identity = identity
      self.teamID = teamID
      self.profileURL = profileURL
      self.sourceEntitlementsURL = sourceEntitlementsURL
      self.configuration = configuration
      self.bundleID = bundleID
      self.product = product
      self.ipaOutputDirectory = ipaOutputDirectory
    }
  }

  public struct Output {
    /// The signed `.app` bundle (signed in place).
    public var appBundle: URL
    /// The packaged `.ipa` file.
    public var ipaURL: URL
    /// Final derived entitlements, ready for inspection or verification.
    public var entitlements: [String: Any]
    /// The parsed embedded provisioning profile.
    public var profile: MobileProvisionParser.ProvisioningProfile

    public init(
      appBundle: URL, ipaURL: URL, entitlements: [String: Any],
      profile: MobileProvisionParser.ProvisioningProfile
    ) {
      self.appBundle = appBundle
      self.ipaURL = ipaURL
      self.entitlements = entitlements
      self.profile = profile
    }
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case identityMissingTeam
    case missingProfile(String)

    public var description: String {
      switch self {
      case .identityMissingTeam:
        return "The stored signing identity has no team ID. Re-run `stupid-app signing setup`."
      case .missingProfile(let path):
        return "No provisioning profile found at '\(path)'. Run `stupid-app signing setup` first."
      }
    }
  }

  /// Derives and reconciles entitlements, embeds the profile, signs once with the
  /// native engine, and packages the IPA. Returns the signed bundle and IPA.
  public static func signAndPackage(input: Input) throws -> Output {
    guard !input.teamID.isEmpty else {
      throw Error.identityMissingTeam
    }
    guard FileManager.default.fileExists(atPath: input.profileURL.path) else {
      throw Error.missingProfile(input.profileURL.path)
    }

    let profile = try MobileProvisionParser.parse(at: input.profileURL)

    // Derive and reconcile final entitlements directly from project and profile inputs.
    let derived = try EntitlementDeriver.derive(
      sourceURL: input.sourceEntitlementsURL,
      configuration: input.configuration,
      bundleID: input.bundleID,
      profile: profile,
      teamID: input.teamID
    )
    // Embed the profile before the single signing pass.
    let embeddedURL = input.unsignedApp.appendingPathComponent("embedded.mobileprovision")
    try FileManager.default.copyItem(at: input.profileURL, to: embeddedURL)

    // One native real signing pass. The public Apple chain is pinned and selected from
    // the leaf issuer; unsupported chain rotations fail without an external fallback.
    let chain = try AppleSigningTrust.chain(forLeafCertificatePEM: input.identity.certificatePEM)
    try NativeSigner().sign(
      appBundle: input.unsignedApp,
      identity: .init(
        privateKeyPEM: input.identity.privateKeyPEM,
        leafCertificatePEM: input.identity.certificatePEM,
        intermediateCertificatePEM: chain.intermediateCertificatePEM,
        trustedRootCertificatesPEM: [chain.rootCertificatePEM]),
      entitlements: derived,
      teamID: input.teamID)

    let ipaURL = try IPAPacker.pack(
      appBundle: input.unsignedApp,
      product: input.product,
      outputDirectory: input.ipaOutputDirectory
    )

    return Output(
      appBundle: input.unsignedApp,
      ipaURL: ipaURL,
      entitlements: derived,
      profile: profile
    )
  }
}

/// Leaf-first signing for a deep app: each nested extension is signed (with its own
/// profile and entitlements) before the containing app, whose `CodeResources` then
/// seals the now-signed nested bundles. The app is signed last with `deep` mode.
public enum DeepSigningPipeline {
  /// Per-bundle signing input for one nested extension.
  public struct ExtensionInput: Sendable {
    /// The unsigned `PlugIns/<Product>.appex` bundle.
    public var appexBundle: URL
    public var identity: IdentityManager.SigningIdentity
    public var teamID: String
    public var profileURL: URL
    public var sourceEntitlementsURL: URL
    public var configuration: EntitlementDeriver.Configuration
    public var bundleID: String

    public init(
      appexBundle: URL, identity: IdentityManager.SigningIdentity, teamID: String,
      profileURL: URL, sourceEntitlementsURL: URL,
      configuration: EntitlementDeriver.Configuration, bundleID: String
    ) {
      self.appexBundle = appexBundle
      self.identity = identity
      self.teamID = teamID
      self.profileURL = profileURL
      self.sourceEntitlementsURL = sourceEntitlementsURL
      self.configuration = configuration
      self.bundleID = bundleID
    }
  }

  /// App-level input, mirroring `SigningPipeline.Input` plus the nested extensions.
  public struct AppInput: Sendable {
    public var unsignedApp: URL
    public var identity: IdentityManager.SigningIdentity
    public var teamID: String
    public var profileURL: URL
    public var sourceEntitlementsURL: URL
    public var configuration: EntitlementDeriver.Configuration
    public var bundleID: String
    public var product: String
    public var ipaOutputDirectory: URL

    public init(
      unsignedApp: URL, identity: IdentityManager.SigningIdentity, teamID: String,
      profileURL: URL, sourceEntitlementsURL: URL,
      configuration: EntitlementDeriver.Configuration, bundleID: String, product: String,
      ipaOutputDirectory: URL
    ) {
      self.unsignedApp = unsignedApp
      self.identity = identity
      self.teamID = teamID
      self.profileURL = profileURL
      self.sourceEntitlementsURL = sourceEntitlementsURL
      self.configuration = configuration
      self.bundleID = bundleID
      self.product = product
      self.ipaOutputDirectory = ipaOutputDirectory
    }
  }

  public struct ExtensionResult {
    public var appexBundle: URL
    public var bundleID: String
    public var entitlements: [String: Any]
    public var profile: MobileProvisionParser.ProvisioningProfile

    public init(
      appexBundle: URL, bundleID: String, entitlements: [String: Any],
      profile: MobileProvisionParser.ProvisioningProfile
    ) {
      self.appexBundle = appexBundle
      self.bundleID = bundleID
      self.entitlements = entitlements
      self.profile = profile
    }
  }

  public struct DeepOutput {
    public var appBundle: URL
    public var ipaURL: URL
    public var entitlements: [String: Any]
    public var profile: MobileProvisionParser.ProvisioningProfile
    public var extensions: [ExtensionResult]

    public init(
      appBundle: URL, ipaURL: URL, entitlements: [String: Any],
      profile: MobileProvisionParser.ProvisioningProfile, extensions: [ExtensionResult]
    ) {
      self.appBundle = appBundle
      self.ipaURL = ipaURL
      self.entitlements = entitlements
      self.profile = profile
      self.extensions = extensions
    }
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case missingProfile(String)
    case missingExtensionProfile(String)

    public var description: String {
      switch self {
      case .missingProfile(let path):
        return "No provisioning profile found at '\(path)'. Run `stupid-app signing setup` first."
      case .missingExtensionProfile(let bundleID):
        return
          "No provisioning profile found for extension bundle '\(bundleID)'. Run `stupid-app signing setup` first."
      }
    }
  }

  /// Signs every nested extension (each with its own profile and entitlements) in
  /// leaf-first order, then signs the containing app in `deep` mode and packages the
  /// IPA. Returns the signed bundle, IPA, and per-bundle signing output.
  public static func signAndPackage(input: AppInput, extensions: [ExtensionInput]) throws
    -> DeepOutput
  {
    var extensionResults: [ExtensionResult] = []
    guard FileManager.default.fileExists(atPath: input.profileURL.path) else {
      throw Error.missingProfile(input.profileURL.path)
    }
    let appProfile = try MobileProvisionParser.parse(at: input.profileURL)

    // Leaf-first: sign every extension before the app.
    for extensionInput in extensions {
      guard FileManager.default.fileExists(atPath: extensionInput.profileURL.path) else {
        throw Error.missingExtensionProfile(extensionInput.bundleID)
      }
      let profile = try MobileProvisionParser.parse(at: extensionInput.profileURL)
      let derived = try EntitlementDeriver.derive(
        sourceURL: extensionInput.sourceEntitlementsURL,
        configuration: extensionInput.configuration,
        bundleID: extensionInput.bundleID,
        profile: profile,
        teamID: extensionInput.teamID
      )
      let embedded =
        extensionInput.appexBundle.appendingPathComponent("embedded.mobileprovision")
      try FileManager.default.copyItem(at: extensionInput.profileURL, to: embedded)
      let chain = try AppleSigningTrust.chain(
        forLeafCertificatePEM: extensionInput.identity.certificatePEM)
      try NativeSigner().sign(
        appBundle: extensionInput.appexBundle,
        identity: .init(
          privateKeyPEM: extensionInput.identity.privateKeyPEM,
          leafCertificatePEM: extensionInput.identity.certificatePEM,
          intermediateCertificatePEM: chain.intermediateCertificatePEM,
          trustedRootCertificatesPEM: [chain.rootCertificatePEM]),
        entitlements: derived,
        teamID: extensionInput.teamID)
      extensionResults.append(
        ExtensionResult(
          appexBundle: extensionInput.appexBundle, bundleID: extensionInput.bundleID,
          entitlements: derived, profile: profile))
    }

    // Sign the containing app last so it seals the now-signed nested bundles.
    let appDerived = try EntitlementDeriver.derive(
      sourceURL: input.sourceEntitlementsURL,
      configuration: input.configuration,
      bundleID: input.bundleID,
      profile: appProfile,
      teamID: input.teamID
    )
    let embeddedApp = input.unsignedApp.appendingPathComponent("embedded.mobileprovision")
    try FileManager.default.copyItem(at: input.profileURL, to: embeddedApp)
    let appChain = try AppleSigningTrust.chain(forLeafCertificatePEM: input.identity.certificatePEM)
    try NativeSigner().sign(
      appBundle: input.unsignedApp,
      identity: .init(
        privateKeyPEM: input.identity.privateKeyPEM,
        leafCertificatePEM: input.identity.certificatePEM,
        intermediateCertificatePEM: appChain.intermediateCertificatePEM,
        trustedRootCertificatesPEM: [appChain.rootCertificatePEM]),
      entitlements: appDerived,
      teamID: input.teamID,
      mode: .deep)

    let ipaURL = try IPAPacker.pack(
      appBundle: input.unsignedApp,
      product: input.product,
      outputDirectory: input.ipaOutputDirectory
    )

    return DeepOutput(
      appBundle: input.unsignedApp,
      ipaURL: ipaURL,
      entitlements: appDerived,
      profile: appProfile,
      extensions: extensionResults
    )
  }
}
