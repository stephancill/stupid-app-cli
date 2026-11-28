import Foundation

  public struct NativeSigner {
  public static let engineVersion = "native-shallow-v1"

  public struct IdentityInput: Sendable {
    public let signer: CMSSigner
    public let leafCertificatePEM: String
    public let intermediateCertificatePEM: String
    public let trustedRootCertificatesPEM: [String]

    public init(
      signer: CMSSigner,
      leafCertificatePEM: String,
      intermediateCertificatePEM: String,
      trustedRootCertificatesPEM: [String]
    ) {
      self.signer = signer
      self.leafCertificatePEM = leafCertificatePEM
      self.intermediateCertificatePEM = intermediateCertificatePEM
      self.trustedRootCertificatesPEM = trustedRootCertificatesPEM
    }
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case missingCertificateChain
    case unstableSignatureSize
    case verificationFailed(String)
    case frameworkEntitlements

    public var description: String {
      switch self {
      case .missingCertificateChain:
        return
          "Native signing requires an explicit WWDR intermediate and at least one trusted Apple root certificate."
      case .unstableSignatureSize:
        return "Native signing could not stabilize the deterministic embedded-signature size."
      case .verificationFailed(let detail):
        return "Native post-sign verification failed: \(detail)."
      case .frameworkEntitlements:
        return "Native signing refuses entitlements for a .framework: frameworks are signed without them."
      }
    }
  }

  public init() {}

  public func sign(
    appBundle: URL,
    identity: IdentityInput,
    entitlements: [String: Any],
    teamID: String,
    flags: UInt32 = 0,
    mode: NativeAppClassifier.Mode = .shallow
  ) throws {
    guard !identity.intermediateCertificatePEM.isEmpty, !identity.trustedRootCertificatesPEM.isEmpty
    else {
      throw Error.missingCertificateChain
    }
    let plan = try NativeAppClassifier.classify(appBundle: appBundle, mode: mode)
    let infoData = try Data(contentsOf: plan.appBundle.appendingPathComponent("Info.plist"))
    let executable = try Data(contentsOf: plan.executableURL)
    let codeResources = try NativeCodeResources.write(
      appBundle: plan.appBundle, executableName: plan.executableName,
      deep: mode == .deep)
    let commonName = try NativeCMS.certificateCommonName(identity.leafCertificatePEM)
    let requirements = try NativeSigningSerialization.requirementSet(
      identifier: plan.bundleIdentifier, leafCommonName: commonName)
    // A framework is signed as Xcode signs it: no entitlement slots, not the main binary.
    guard !plan.isFramework || entitlements.isEmpty else { throw Error.frameworkEntitlements }
    var specialContent: [UInt32: Data] = [1: infoData, 2: requirements, 3: codeResources]
    var entitlementBlobs: [(UInt32, Data)] = []
    if !plan.isFramework {
      let xml = try PropertyListSerialization.data(
        fromPropertyList: entitlements, format: .xml, options: 0)
      let xmlBlob = NativeEmbeddedSignature.blob(magic: 0xFADE_7171, payload: xml)
      let derBlob = NativeEmbeddedSignature.blob(
        magic: 0xFADE_7172,
        payload: try NativeSigningSerialization.entitlementDER(entitlements))
      specialContent[5] = xmlBlob
      specialContent[7] = derBlob
      entitlementBlobs = [(5, xmlBlob), (7, derBlob)]
    }
    let specialHashes = specialContent.mapValues(NativeEmbeddedSignature.digest)
    var executableSegmentFlags: UInt64 = plan.isFramework ? 0 : 0x1  // MAIN_BINARY
    if entitlements["get-task-allow"] as? Bool == true {
      executableSegmentFlags |= 0x10  // ALLOW_UNSIGNED
    }

    func superBlob(codeDirectory: Data, cms: Data) -> Data {
      NativeEmbeddedSignature.superBlob(
        [(0, codeDirectory), (2, requirements)] + entitlementBlobs + [
          (0x1_0000, NativeEmbeddedSignature.blob(magic: 0xFADE_0B01, payload: cms))
        ])
    }

    // Settle the embedded-signature size with a same-size placeholder CMS, then sign the
    // final CodeDirectory once: a remote signer is asked for exactly one signature.
    var expectedSize = 0
    var settled: (layout: NativeMachOEditor.Layout, codeDirectory: Data)?
    for _ in 0..<4 {
      let layout = try NativeMachOEditor.layout(executable: executable, signatureSize: expectedSize)
      let codeDirectory = NativeEmbeddedSignature.codeDirectory(
        executablePrefix: layout.prefix,
        identifier: plan.bundleIdentifier,
        teamID: teamID,
        specialSlots: specialHashes,
        flags: flags,
        executableSegmentFlags: executableSegmentFlags,
        executableSegmentBase: layout.executableSegmentBase,
        executableSegmentLimit: layout.executableSegmentLimit)
      let placeholder = try NativeCMS.sizingPlaceholder(
        codeDirectory: codeDirectory,
        leafCertificatePEM: identity.leafCertificatePEM,
        intermediateCertificatePEM: identity.intermediateCertificatePEM,
        rootCertificatePEM: identity.trustedRootCertificatesPEM[0])
      let size = superBlob(codeDirectory: codeDirectory, cms: placeholder).count
      if size == expectedSize {
        settled = (layout, codeDirectory)
        break
      }
      expectedSize = size
    }
    guard let settled else { throw Error.unstableSignatureSize }
    let cms = try NativeCMS.sign(
      codeDirectory: settled.codeDirectory,
      signer: identity.signer,
      leafCertificatePEM: identity.leafCertificatePEM,
      intermediateCertificatePEM: identity.intermediateCertificatePEM,
      rootCertificatePEM: identity.trustedRootCertificatesPEM[0])
    let signature = superBlob(codeDirectory: settled.codeDirectory, cms: cms)
    guard signature.count == expectedSize else { throw Error.unstableSignatureSize }
    let finalExecutable = settled.layout.prefix + signature

    _ = try NativeSignatureVerifier.verifyCodeDirectoryHashes(
      executable: finalExecutable,
      externalSpecialSlots: [1: infoData, 3: codeResources])
    _ = try NativeSignatureVerifier.verifyCMS(
      executable: finalExecutable,
      trustedRootCertificatesPEM: identity.trustedRootCertificatesPEM)
    try NativeCodeResources.verify(
      appBundle: plan.appBundle, executableName: plan.executableName, data: codeResources,
      deep: mode == .deep)
    try finalExecutable.write(to: plan.executableURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: plan.executableURL.path)
  }

  /// Ad-hoc signs one `.app`, `.appex` or `.framework` for a simulator, the signature `codesign -s -`
  /// makes: a CodeDirectory flagged `CS_ADHOC` with no team, an empty requirement set and
  /// an empty CMS wrapper. Only simulator builds use it (the scoped simulator exception);
  /// device and release output always gets a real identity through `sign`. Sign nested
  /// `.appex` bundles first and their container last with `mode: .deep`, so the container
  /// seals the signed extensions.
  public func adHocSign(
    appBundle: URL,
    entitlements: [String: Any],
    mode: NativeAppClassifier.Mode = .shallow
  ) throws {
    let csAdhoc: UInt32 = 0x0000_0002
    let plan = try NativeAppClassifier.classify(appBundle: appBundle, mode: mode)
    guard !plan.isFramework || entitlements.isEmpty else { throw Error.frameworkEntitlements }
    let infoData = try Data(contentsOf: plan.appBundle.appendingPathComponent("Info.plist"))
    let executable = try Data(contentsOf: plan.executableURL)
    let codeResources = try NativeCodeResources.write(
      appBundle: plan.appBundle, executableName: plan.executableName,
      deep: mode == .deep)
    // An empty requirement set: magic, length 12, no requirements.
    let requirements = Data([0xFA, 0xDE, 0x0C, 0x01, 0, 0, 0, 12, 0, 0, 0, 0])
    var specialContent: [UInt32: Data] = [1: infoData, 2: requirements, 3: codeResources]
    var entitlementBlobs: [(UInt32, Data)] = []
    if !entitlements.isEmpty {
      let xml = try PropertyListSerialization.data(
        fromPropertyList: entitlements, format: .xml, options: 0)
      let xmlBlob = NativeEmbeddedSignature.blob(magic: 0xFADE_7171, payload: xml)
      let derBlob = NativeEmbeddedSignature.blob(
        magic: 0xFADE_7172,
        payload: try NativeSigningSerialization.entitlementDER(entitlements))
      specialContent[5] = xmlBlob
      specialContent[7] = derBlob
      entitlementBlobs = [(5, xmlBlob), (7, derBlob)]
    }
    let specialHashes = specialContent.mapValues(NativeEmbeddedSignature.digest)
    var executableSegmentFlags: UInt64 = plan.isFramework ? 0 : 0x1  // MAIN_BINARY
    if entitlements["get-task-allow"] as? Bool == true {
      executableSegmentFlags |= 0x10  // ALLOW_UNSIGNED
    }
    let emptyCMS = NativeEmbeddedSignature.blob(magic: 0xFADE_0B01, payload: Data())

    var expectedSize = 0
    var finalExecutable: Data?
    for _ in 0..<4 {
      let layout = try NativeMachOEditor.layout(executable: executable, signatureSize: expectedSize)
      let codeDirectory = NativeEmbeddedSignature.codeDirectory(
        executablePrefix: layout.prefix,
        identifier: plan.bundleIdentifier,
        teamID: "",
        specialSlots: specialHashes,
        flags: csAdhoc,
        executableSegmentFlags: executableSegmentFlags,
        executableSegmentBase: layout.executableSegmentBase,
        executableSegmentLimit: layout.executableSegmentLimit)
      let superBlob = NativeEmbeddedSignature.superBlob(
        [(0, codeDirectory), (2, requirements)] + entitlementBlobs + [(0x1_0000, emptyCMS)])
      if superBlob.count == expectedSize {
        finalExecutable = layout.prefix + superBlob
        break
      }
      expectedSize = superBlob.count
    }
    guard let finalExecutable else { throw Error.unstableSignatureSize }

    // NativeSignatureVerifier models the device signature (exactly one designated
    // requirement and a CMS chain), which an ad-hoc signature deliberately lacks; Apple's
    // `codesign --verify --strict` is the check for this format (NativeAdHocSignerTests).
    try NativeCodeResources.verify(
      appBundle: plan.appBundle, executableName: plan.executableName, data: codeResources,
      deep: mode == .deep)
    try finalExecutable.write(to: plan.executableURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: plan.executableURL.path)
  }
}
