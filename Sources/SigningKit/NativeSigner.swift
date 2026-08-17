import Foundation

public struct NativeSigner {
  public static let engineVersion = "native-shallow-v1"

  public struct IdentityInput: Sendable {
    public let privateKeyPEM: String
    public let leafCertificatePEM: String
    public let intermediateCertificatePEM: String
    public let trustedRootCertificatesPEM: [String]

    public init(
      privateKeyPEM: String,
      leafCertificatePEM: String,
      intermediateCertificatePEM: String,
      trustedRootCertificatesPEM: [String]
    ) {
      self.privateKeyPEM = privateKeyPEM
      self.leafCertificatePEM = leafCertificatePEM
      self.intermediateCertificatePEM = intermediateCertificatePEM
      self.trustedRootCertificatesPEM = trustedRootCertificatesPEM
    }
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case missingCertificateChain
    case unstableSignatureSize
    case verificationFailed(String)

    public var description: String {
      switch self {
      case .missingCertificateChain:
        return
          "Native signing requires an explicit WWDR intermediate and at least one trusted Apple root certificate."
      case .unstableSignatureSize:
        return "Native signing could not stabilize the deterministic embedded-signature size."
      case .verificationFailed(let detail):
        return "Native post-sign verification failed: \(detail)."
      }
    }
  }

  public init() {}

  public func sign(
    appBundle: URL,
    identity: IdentityInput,
    entitlements: [String: Any],
    teamID: String,
    flags: UInt32 = 0
  ) throws {
    guard !identity.intermediateCertificatePEM.isEmpty, !identity.trustedRootCertificatesPEM.isEmpty
    else {
      throw Error.missingCertificateChain
    }
    let plan = try NativeAppClassifier.classify(appBundle: appBundle)
    let infoData = try Data(contentsOf: plan.appBundle.appendingPathComponent("Info.plist"))
    let executable = try Data(contentsOf: plan.executableURL)
    let codeResources = try NativeCodeResources.write(
      appBundle: plan.appBundle, executableName: plan.executableName)
    let commonName = try NativeCMS.certificateCommonName(identity.leafCertificatePEM)
    let requirements = try NativeSigningSerialization.requirementSet(
      identifier: plan.bundleIdentifier, leafCommonName: commonName)
    let xml = try PropertyListSerialization.data(
      fromPropertyList: entitlements, format: .xml, options: 0)
    let xmlBlob = NativeEmbeddedSignature.blob(magic: 0xFADE_7171, payload: xml)
    let derBlob = NativeEmbeddedSignature.blob(
      magic: 0xFADE_7172,
      payload: try NativeSigningSerialization.entitlementDER(entitlements))
    let specialContent: [UInt32: Data] = [
      1: infoData, 2: requirements, 3: codeResources, 5: xmlBlob, 7: derBlob,
    ]
    let specialHashes = specialContent.mapValues(NativeEmbeddedSignature.digest)
    var executableSegmentFlags: UInt64 = 0x1  // MAIN_BINARY
    if entitlements["get-task-allow"] as? Bool == true {
      executableSegmentFlags |= 0x10  // ALLOW_UNSIGNED
    }

    var expectedSize = 0
    var finalExecutable: Data?
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
      let cms = try NativeCMS.sign(
        codeDirectory: codeDirectory,
        privateKeyPEM: identity.privateKeyPEM,
        leafCertificatePEM: identity.leafCertificatePEM,
        intermediateCertificatePEM: identity.intermediateCertificatePEM,
        rootCertificatePEM: identity.trustedRootCertificatesPEM[0])
      let cmsBlob = NativeEmbeddedSignature.blob(magic: 0xFADE_0B01, payload: cms)
      let superBlob = NativeEmbeddedSignature.superBlob([
        (0, codeDirectory), (2, requirements), (5, xmlBlob), (7, derBlob), (0x1_0000, cmsBlob),
      ])
      if superBlob.count == expectedSize {
        finalExecutable = layout.prefix + superBlob
        break
      }
      expectedSize = superBlob.count
    }
    guard let finalExecutable else { throw Error.unstableSignatureSize }

    _ = try NativeSignatureVerifier.verifyCodeDirectoryHashes(
      executable: finalExecutable,
      externalSpecialSlots: [1: infoData, 3: codeResources])
    _ = try NativeSignatureVerifier.verifyCMS(
      executable: finalExecutable,
      trustedRootCertificatesPEM: identity.trustedRootCertificatesPEM)
    try NativeCodeResources.verify(
      appBundle: plan.appBundle, executableName: plan.executableName, data: codeResources)
    try finalExecutable.write(to: plan.executableURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: plan.executableURL.path)
  }
}
