import Crypto
import Foundation
import Testing
import X509
import _CryptoExtras

@testable import SigningKit

struct NativeSigningSerializationTests {
  @Test("loads the pinned qualified Apple signing chain")
  func loadsAppleSigningTrust() throws {
    let chain = try AppleSigningTrust.loadQualifiedChain()
    #expect(chain.intermediateCertificatePEM.contains("BEGIN CERTIFICATE"))
    #expect(chain.rootCertificatePEM.contains("BEGIN CERTIFICATE"))
  }

  @Test("rejects signing identities outside the qualified Apple chain")
  func rejectsUnsupportedSigningChain() throws {
    let fixture = try certificateFixture()
    #expect(throws: AppleSigningTrust.Error.unsupportedLeafIssuer) {
      try AppleSigningTrust.chain(forLeafCertificatePEM: fixture.leafPEM)
    }
  }

  @Test("serializes canonical Apple DER entitlements and RequirementSet")
  func serializesEntitlementsAndRequirements() throws {
    let entitlements: [String: Any] = [
      "z-value": 7,
      "enabled": true,
      "array": ["one", "two"],
      "nested": ["key": false],
    ]
    let first = try NativeSigningSerialization.entitlementDER(entitlements)
    let second = try NativeSigningSerialization.entitlementDER(entitlements)
    #expect(first == second)
    #expect(first.first == 0x70)

    let requirement = try NativeSigningSerialization.requirementSet(
      identifier: "net.example.fixture", leafCommonName: "Apple Development: Fixture")
    #expect(readBE32(requirement, 0) == 0xFADE_0C01)
    #expect(requirement.range(of: Data("net.example.fixture".utf8)) != nil)
    #expect(requirement.range(of: Data("Apple Development: Fixture".utf8)) != nil)
  }

  @Test("creates and independently verifies detached RSA CMS without a timestamp")
  func signsAndVerifiesCMS() throws {
    let fixture = try certificateFixture()
    let codeDirectory = Data("deterministic-code-directory".utf8)
    let cms = try NativeCMS.sign(
      codeDirectory: codeDirectory,
      privateKeyPEM: fixture.leafKey.pkcs8PEMRepresentation,
      leafCertificatePEM: fixture.leafPEM,
      intermediateCertificatePEM: fixture.intermediatePEM,
      rootCertificatePEM: fixture.rootPEM)
    let repeated = try NativeCMS.sign(
      codeDirectory: codeDirectory,
      privateKeyPEM: fixture.leafKey.pkcs8PEMRepresentation,
      leafCertificatePEM: fixture.leafPEM,
      intermediateCertificatePEM: fixture.intermediatePEM,
      rootCertificatePEM: fixture.rootPEM)
    #expect(cms == repeated)

    let result = try NativeCMS.verify(
      cms: cms,
      codeDirectory: codeDirectory,
      trustedRootCertificatesPEM: [fixture.rootPEM])
    #expect(result.certificateCount == 3)
    #expect(result.cdhash == Data(SHA256.hash(data: codeDirectory)))
    #expect(!result.hasTimestamp)

    #expect(throws: NativeCMS.Error.self) {
      try NativeCMS.verify(
        cms: cms,
        codeDirectory: Data("changed".utf8),
        trustedRootCertificatesPEM: [fixture.rootPEM])
    }
  }

  @Test("adds and replaces final LC_CODE_SIGNATURE deterministically")
  func editsMachO() throws {
    let unsigned = makeUnsignedMachO()
    let signature = Data(repeating: 0xA5, count: 333)
    let first = try NativeMachOEditor.embed(executable: unsigned, signature: signature)
    let second = try NativeMachOEditor.embed(executable: first, signature: signature)
    #expect(first == second)
    #expect(readLE32(first, 16) == 3)
    #expect(readLE32(first, 20) == 160)
    #expect(readLE32(first, 176) == 0x1D)
    #expect(Int(readLE32(first, 184)) + signature.count == first.count)
    #expect(readLE64(first, 152) == UInt64(first.count - 4096))
    #expect(readLE64(first, 136).isMultiple(of: 16_384))
  }

  @Test("classifies only a shallow app and rejects nested code")
  func classifiesShallowApp() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("native-classifier-\(UUID().uuidString).app", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundleExecutable": "Fixture", "CFBundleIdentifier": "net.example.fixture",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: root.appendingPathComponent("Info.plist"))
    let executable = root.appendingPathComponent("Fixture")
    try makeUnsignedMachO().write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let plan = try NativeAppClassifier.classify(appBundle: root)
    #expect(plan.bundleIdentifier == "net.example.fixture")

    try Data("library".utf8).write(to: root.appendingPathComponent("libFixture.dylib"))
    #expect(throws: NativeAppClassifier.Error.self) {
      try NativeAppClassifier.classify(appBundle: root)
    }
  }

  @Test("signs and independently verifies a complete synthetic shallow app")
  func signsSyntheticApp() throws {
    let certificates = try certificateFixture()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("native-signer-\(UUID().uuidString).app", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundleExecutable": "Fixture", "CFBundleIdentifier": "net.example.fixture",
    ]
    let infoData = try PropertyListSerialization.data(
      fromPropertyList: info, format: .xml, options: 0)
    try infoData.write(to: root.appendingPathComponent("Info.plist"))
    let executableURL = root.appendingPathComponent("Fixture")
    try makeUnsignedMachO().write(to: executableURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    try Data("profile".utf8).write(to: root.appendingPathComponent("embedded.mobileprovision"))

    try NativeSigner().sign(
      appBundle: root,
      identity: .init(
        privateKeyPEM: certificates.leafKey.pkcs8PEMRepresentation,
        leafCertificatePEM: certificates.leafPEM,
        intermediateCertificatePEM: certificates.intermediatePEM,
        trustedRootCertificatesPEM: [certificates.rootPEM]),
      entitlements: [
        "application-identifier": "TEAMID1234.net.example.fixture", "get-task-allow": true,
      ],
      teamID: "TEAMID1234")

    let executable = try Data(contentsOf: executableURL)
    let codeResources = try Data(
      contentsOf: root.appendingPathComponent("_CodeSignature/CodeResources"))
    let signature = try NativeSignatureVerifier.verifyCodeDirectoryHashes(
      executable: executable,
      externalSpecialSlots: [1: infoData, 3: codeResources])
    #expect(signature.codeDirectory.identifier == "net.example.fixture")
    #expect(signature.entitlements["get-task-allow"] == .boolean(true))
    #expect(signature.codeDirectory.executableSegmentFlags == 0x11)
    let cms = try NativeSignatureVerifier.verifyCMS(
      executable: executable, trustedRootCertificatesPEM: [certificates.rootPEM])
    #expect(!cms.hasTimestamp)
  }
}

private struct CertificateFixture {
  let leafKey: _RSA.Signing.PrivateKey
  let rootPEM: String
  let intermediatePEM: String
  let leafPEM: String
}

private func certificateFixture() throws -> CertificateFixture {
  let rootKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
  let intermediateKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
  let leafKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
  let rootName = try DistinguishedName { CommonName("Synthetic Apple Root") }
  let intermediateName = try DistinguishedName { CommonName("Synthetic WWDR") }
  let leafName = try DistinguishedName { CommonName("Apple Development: Fixture") }
  let before = Date().addingTimeInterval(-3600)
  let after = Date().addingTimeInterval(3600)
  let root = try Certificate(
    version: .v3, serialNumber: .init(), publicKey: .init(rootKey.publicKey),
    notValidBefore: before, notValidAfter: after, issuer: rootName, subject: rootName,
    signatureAlgorithm: .sha256WithRSAEncryption,
    extensions: Certificate.Extensions {
      Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 2))
    },
    issuerPrivateKey: .init(rootKey))
  let intermediate = try Certificate(
    version: .v3, serialNumber: .init(), publicKey: .init(intermediateKey.publicKey),
    notValidBefore: before, notValidAfter: after, issuer: root.subject, subject: intermediateName,
    signatureAlgorithm: .sha256WithRSAEncryption,
    extensions: Certificate.Extensions {
      Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 1))
      Certificate.Extension(
        oid: [1, 2, 840, 113635, 100, 6, 2, 1], critical: false, value: [0x05, 0x00])
    },
    issuerPrivateKey: .init(rootKey))
  let leaf = try Certificate(
    version: .v3, serialNumber: .init(), publicKey: .init(leafKey.publicKey),
    notValidBefore: before, notValidAfter: after, issuer: intermediate.subject, subject: leafName,
    signatureAlgorithm: .sha256WithRSAEncryption,
    extensions: Certificate.Extensions { Critical(BasicConstraints.notCertificateAuthority) },
    issuerPrivateKey: .init(intermediateKey))
  return CertificateFixture(
    leafKey: leafKey,
    rootPEM: try root.serializeAsPEM().pemString,
    intermediatePEM: try intermediate.serializeAsPEM().pemString,
    leafPEM: try leaf.serializeAsPEM().pemString)
}

private func makeUnsignedMachO() -> Data {
  var data = Data()
  data += le32s(0xFEED_FACF) + le32s(0x0100_000C) + le32s(0) + le32s(2)
  data += le32s(2) + le32s(144) + le32s(0) + le32s(0)
  data += le32s(0x19) + le32s(72) + segmentNameForSigning("__TEXT")
  data += le64s(0x1_0000_0000) + le64s(4096) + le64s(0) + le64s(4096)
  data += le32s(7) + le32s(5) + le32s(0) + le32s(0)
  data += le32s(0x19) + le32s(72) + segmentNameForSigning("__LINKEDIT")
  data += le64s(0x1_0000_0000) + le64s(128) + le64s(4096) + le64s(128)
  data += le32s(0) + le32s(0) + le32s(0) + le32s(0)
  data += Data(repeating: 0, count: 4096 - data.count)
  data += Data(repeating: 0x3C, count: 128)
  return data
}

private func readBE32(_ data: Data, _ offset: Int) -> UInt32 {
  data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian }
}
private func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
  data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
}
private func readLE64(_ data: Data, _ offset: Int) -> UInt64 {
  data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian }
}
private func le32s(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
private func le64s(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
private func segmentNameForSigning(_ value: String) -> Data {
  Data(value.utf8) + Data(repeating: 0, count: 16 - value.utf8.count)
}
