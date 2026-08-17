import Crypto
import Foundation
import Testing

@testable import SigningKit

struct NativeSignatureVerifierTests {
  @Test("parses and verifies the supported ARM64 signature shape")
  func verifiesSupportedSignature() throws {
    let fixture = makeFixture()
    let signature = try NativeSignatureVerifier.verifyCodeDirectoryHashes(
      executable: fixture.executable,
      externalSpecialSlots: [1: fixture.infoPlist]
    )

    #expect(signature.signatureOffset == 8_192)
    #expect(signature.codeDirectory.identifier == "net.example.fixture")
    #expect(signature.codeDirectory.teamIdentifier == "TEAMID1234")
    #expect(signature.codeDirectory.pageSize == 4_096)
    #expect(signature.codeDirectory.codeHashes.count == 2)
    #expect(signature.codeDirectory.executableSegmentFlags == 1)
    #expect(signature.blobs.map(\.slot) == [0, 2, 5, 7, 0x1_0000])
    #expect(signature.entitlements["get-task-allow"] == .boolean(true))
    #expect(
      signature.entitlements["keychain-access-groups"]
        == .array([.string("TEAMID1234.*")]))
    #expect(signature.entitlements["aps-environment"] == .string("development"))
    #expect(signature.entitlements["version"] == .integer(42))
    #expect(
      signature.entitlements["nested"]
        == .dictionary(["enabled": .boolean(false)]))
    #expect(signature.designatedRequirement == fixtureDesignatedRequirementExpression())
  }

  @Test("detects a changed code page")
  func rejectsCodeMutation() {
    let fixture = makeFixture()
    var executable = fixture.executable
    executable[4_200] ^= 0x01

    #expect(throws: NativeSignatureVerifier.Error.codePageMismatch(1)) {
      try NativeSignatureVerifier.verifyCodeDirectoryHashes(
        executable: executable,
        externalSpecialSlots: [1: fixture.infoPlist]
      )
    }
  }

  @Test("detects changed embedded special-slot content")
  func rejectsEmbeddedSlotMutation() throws {
    let fixture = makeFixture()
    let signature = try NativeSignatureVerifier.parse(executable: fixture.executable)
    let requirements = try #require(signature.blobs.first(where: { $0.slot == 2 }))
    let payload = Data("Apple Development: Fixture".utf8)
    let payloadOffset = try #require(fixture.executable.range(of: payload)?.lowerBound)
    #expect(requirements.data.contains(payload))

    var executable = fixture.executable
    executable[payloadOffset] ^= 0x01
    #expect(throws: NativeSignatureVerifier.Error.specialSlotMismatch(2)) {
      try NativeSignatureVerifier.verifyCodeDirectoryHashes(
        executable: executable,
        externalSpecialSlots: [1: fixture.infoPlist]
      )
    }
  }

  @Test("rejects a designated requirement identifier mismatch")
  func rejectsRequirementIdentifierMismatch() throws {
    let fixture = makeFixture()
    let signature = try NativeSignatureVerifier.parse(executable: fixture.executable)
    let requirements = try #require(signature.blobs.first(where: { $0.slot == 2 }))
    let requirementOffset = try #require(
      fixture.executable.range(of: requirements.data)?.lowerBound)
    let identifier = Data("net.example.fixture".utf8)
    let identifierOffset = try #require(requirements.data.range(of: identifier)?.lowerBound)

    var executable = fixture.executable
    executable[requirementOffset + identifierOffset] = Character("x").asciiValue!
    #expect(throws: NativeSignatureVerifier.Error.self) {
      try NativeSignatureVerifier.parse(executable: executable)
    }
  }

  @Test("rejects requirement opcodes outside the shallow signing scope")
  func rejectsUnsupportedRequirementOpcode() throws {
    let fixture = makeFixture()
    let signature = try NativeSignatureVerifier.parse(executable: fixture.executable)
    let requirements = try #require(signature.blobs.first(where: { $0.slot == 2 }))
    let requirementOffset = try #require(
      fixture.executable.range(of: requirements.data)?.lowerBound)
    let anchorOpcode = be32(15)
    let anchorOffset = try #require(requirements.data.range(of: anchorOpcode)?.lowerBound)

    var executable = fixture.executable
    executable.replaceSubrange(
      (requirementOffset + anchorOffset)..<(requirementOffset + anchorOffset + 4),
      with: be32(7))
    #expect(throws: NativeSignatureVerifier.Error.self) {
      try NativeSignatureVerifier.parse(executable: executable)
    }
  }

  @Test("rejects malformed requirement offsets and padding")
  func rejectsMalformedRequirementStructure() throws {
    let fixture = makeFixture()
    let signature = try NativeSignatureVerifier.parse(executable: fixture.executable)
    let requirements = try #require(signature.blobs.first(where: { $0.slot == 2 }))
    let requirementOffset = try #require(
      fixture.executable.range(of: requirements.data)?.lowerBound)

    var invalidOffset = fixture.executable
    invalidOffset.replaceSubrange(
      (requirementOffset + 16)..<(requirementOffset + 20), with: be32(UInt32.max))
    #expect(throws: NativeSignatureVerifier.Error.self) {
      try NativeSignatureVerifier.parse(executable: invalidOffset)
    }

    let identifier = Data("net.example.fixture".utf8)
    let identifierOffset = try #require(requirements.data.range(of: identifier)?.lowerBound)
    var invalidPadding = fixture.executable
    invalidPadding[requirementOffset + identifierOffset + identifier.count] = 1
    #expect(throws: NativeSignatureVerifier.Error.self) {
      try NativeSignatureVerifier.parse(executable: invalidPadding)
    }
  }

  @Test("detects XML and DER entitlement mismatch")
  func rejectsEntitlementMismatch() throws {
    let fixture = makeFixture()
    let signature = try NativeSignatureVerifier.parse(executable: fixture.executable)
    let der = try #require(signature.blobs.first(where: { $0.slot == 7 }))
    let trueValue = Data([0x01, 0x01, 0xFF])
    let trueOffsetInBlob = try #require(der.data.range(of: trueValue)?.lowerBound)
    let derOffsetInExecutable = try #require(fixture.executable.range(of: der.data)?.lowerBound)

    var executable = fixture.executable
    executable[derOffsetInExecutable + trueOffsetInBlob + 2] = 0
    #expect(throws: NativeSignatureVerifier.Error.entitlementMismatch) {
      try NativeSignatureVerifier.parse(executable: executable)
    }
  }

  @Test("rejects malformed DER entitlement dictionaries")
  func rejectsMalformedDEREntitlements() throws {
    let fixture = makeFixture()
    let signature = try NativeSignatureVerifier.parse(executable: fixture.executable)
    let der = try #require(signature.blobs.first(where: { $0.slot == 7 }))
    let firstKey = Data("get-task-allow".utf8)
    let firstKeyOffset = try #require(der.data.range(of: firstKey)?.lowerBound)
    let derOffsetInExecutable = try #require(fixture.executable.range(of: der.data)?.lowerBound)

    var executable = fixture.executable
    executable[derOffsetInExecutable + firstKeyOffset] = Character("z").asciiValue!
    #expect(throws: NativeSignatureVerifier.Error.self) {
      try NativeSignatureVerifier.parse(executable: executable)
    }
  }

  @Test("detects changed and missing external special-slot content")
  func rejectsExternalSlotMutation() {
    let fixture = makeFixture()
    var changedInfo = fixture.infoPlist
    changedInfo[0] ^= 0x01

    #expect(throws: NativeSignatureVerifier.Error.specialSlotMismatch(1)) {
      try NativeSignatureVerifier.verifyCodeDirectoryHashes(
        executable: fixture.executable,
        externalSpecialSlots: [1: changedInfo]
      )
    }
    #expect(throws: NativeSignatureVerifier.Error.specialSlotContentMissing(1)) {
      try NativeSignatureVerifier.verifyCodeDirectoryHashes(executable: fixture.executable)
    }
    #expect(throws: NativeSignatureVerifier.Error.self) {
      try NativeSignatureVerifier.verifyCodeDirectoryHashes(
        executable: fixture.executable,
        externalSpecialSlots: [1: fixture.infoPlist, 3: Data("unsealed".utf8)]
      )
    }
  }

  @Test("normalizes sliced Data before applying relative offsets")
  func verifiesDataSlice() throws {
    let fixture = makeFixture()
    var storage = Data([0xFF])
    storage.append(fixture.executable)
    let slice = storage.dropFirst()
    #expect(slice.startIndex == 1)

    let signature = try NativeSignatureVerifier.verifyCodeDirectoryHashes(
      executable: slice,
      externalSpecialSlots: [1: fixture.infoPlist]
    )
    #expect(signature.signatureOffset == 8_192)
  }

  @Test("rejects malformed and truncated signatures safely")
  func rejectsMalformedInputs() {
    let fixture = makeFixture()
    var invalidOffset = fixture.executable
    invalidOffset.replaceSubrange(8_192 + 16..<(8_192 + 20), with: be32(UInt32.max))

    #expect(throws: NativeSignatureVerifier.Error.self) {
      try NativeSignatureVerifier.parse(executable: invalidOffset)
    }
    #expect(throws: NativeSignatureVerifier.Error.self) {
      try NativeSignatureVerifier.parse(executable: Data(fixture.executable.dropLast()))
    }
    #expect(throws: NativeSignatureVerifier.Error.self) {
      try NativeSignatureVerifier.parse(executable: Data([0xCA, 0xFE, 0xBA, 0xBE]))
    }

    var misplacedSignature = fixture.executable
    misplacedSignature.replaceSubrange(72..<80, with: le64(8_191))
    #expect(throws: NativeSignatureVerifier.Error.self) {
      try NativeSignatureVerifier.parse(executable: misplacedSignature)
    }
  }
}

private struct SignatureFixture {
  let executable: Data
  let infoPlist: Data
}

private func makeFixture() -> SignatureFixture {
  let signatureOffset = 8_192
  let infoPlist = Data("fixture-info-plist".utf8)
  let requirements = fixtureRequirementSet()
  let entitlementDictionary: [String: Any] = [
    "aps-environment": "development",
    "get-task-allow": true,
    "keychain-access-groups": ["TEAMID1234.*"],
    "nested": ["enabled": false],
    "version": 42,
  ]
  let entitlementXML = try! PropertyListSerialization.data(
    fromPropertyList: entitlementDictionary, format: .xml, options: 0)
  let entitlements = blob(magic: 0xFADE_7171, payload: entitlementXML)
  let derEntitlements = blob(magic: 0xFADE_7172, payload: fixtureDEREntitlements())
  let cms = blob(magic: 0xFADE_0B01, payload: Data("unauthenticated-cms-placeholder".utf8))

  let placeholderCodeDirectory = codeDirectory(
    codeLimit: signatureOffset,
    codeHashes: [Data(repeating: 0, count: 32), Data(repeating: 0, count: 32)],
    specialSlots: [
      1: digest(infoPlist),
      2: digest(requirements),
      5: digest(entitlements),
      7: digest(derEntitlements),
    ]
  )
  let signatureSize =
    12 + 5 * 8 + placeholderCodeDirectory.count + requirements.count + entitlements.count
    + derEntitlements.count + cms.count

  var executable = Data()
  executable.append(le32(0xFEED_FACF))
  executable.append(le32(0x0100_000C))
  executable.append(le32(0))
  executable.append(le32(2))
  executable.append(le32(2))
  executable.append(le32(88))
  executable.append(le32(0))
  executable.append(le32(0))
  executable.append(le32(0x19))
  executable.append(le32(72))
  executable.append(segmentName("__LINKEDIT"))
  executable.append(le64(0))
  executable.append(le64(UInt64(signatureSize)))
  executable.append(le64(UInt64(signatureOffset)))
  executable.append(le64(UInt64(signatureSize)))
  executable.append(le32(0))
  executable.append(le32(0))
  executable.append(le32(0))
  executable.append(le32(0))
  executable.append(le32(0x1D))
  executable.append(le32(16))
  executable.append(le32(UInt32(signatureOffset)))
  executable.append(le32(UInt32(signatureSize)))
  executable.append(Data(repeating: 0xA5, count: signatureOffset - executable.count))

  let codeHashes = stride(from: 0, to: signatureOffset, by: 4_096).map {
    digest(executable.subdata(in: $0..<min($0 + 4_096, signatureOffset)))
  }
  let finalCodeDirectory = codeDirectory(
    codeLimit: signatureOffset,
    codeHashes: codeHashes,
    specialSlots: [
      1: digest(infoPlist),
      2: digest(requirements),
      5: digest(entitlements),
      7: digest(derEntitlements),
    ]
  )
  let blobs: [(UInt32, Data)] = [
    (0, finalCodeDirectory),
    (2, requirements),
    (5, entitlements),
    (7, derEntitlements),
    (0x1_0000, cms),
  ]
  executable.append(superBlob(blobs))
  precondition(executable.count == signatureOffset + signatureSize)
  return SignatureFixture(executable: executable, infoPlist: infoPlist)
}

private func fixtureDesignatedRequirementExpression()
  -> NativeSignatureVerifier.RequirementExpression
{
  .and(
    .identifier("net.example.fixture"),
    .and(
      .anchorAppleGeneric,
      .and(
        .certificateField(
          slot: 0,
          field: "subject.CN",
          match: .equal(Data("Apple Development: Fixture".utf8))),
        .certificateGeneric(
          slot: 1,
          oid: Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x06, 0x02, 0x01]),
          match: .exists))))
}

private func fixtureRequirementSet() -> Data {
  let expression =
    requirementAnd(
      requirementIdentifier("net.example.fixture"),
      requirementAnd(
        be32(15),
        requirementAnd(
          requirementCertificateField(
            slot: 0,
            field: "subject.CN",
            match: requirementEqual(Data("Apple Development: Fixture".utf8))),
          requirementCertificateGeneric(
            slot: 1,
            oid: Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x06, 0x02, 0x01]),
            match: be32(0)))))
  let requirement = blob(
    magic: 0xFADE_0C00,
    payload: be32(1) + expression)
  let payload = be32(1) + be32(3) + be32(20) + requirement
  return blob(magic: 0xFADE_0C01, payload: payload)
}

private func requirementAnd(_ lhs: Data, _ rhs: Data) -> Data {
  be32(6) + lhs + rhs
}

private func requirementIdentifier(_ identifier: String) -> Data {
  be32(2) + requirementData(Data(identifier.utf8))
}

private func requirementCertificateField(
  slot: Int32,
  field: String,
  match: Data
) -> Data {
  be32(11) + be32(UInt32(bitPattern: slot)) + requirementData(Data(field.utf8)) + match
}

private func requirementCertificateGeneric(
  slot: Int32,
  oid: Data,
  match: Data
) -> Data {
  be32(14) + be32(UInt32(bitPattern: slot)) + requirementData(oid) + match
}

private func requirementEqual(_ value: Data) -> Data {
  be32(1) + requirementData(value)
}

private func requirementData(_ value: Data) -> Data {
  let padding = (4 - value.count % 4) % 4
  return be32(UInt32(value.count)) + value + Data(repeating: 0, count: padding)
}

private func fixtureDEREntitlements() -> Data {
  // Apple DER plist envelope version 1 containing a sorted context-specific dictionary.
  let apsEnvironment = derSequence(
    derUTF8("aps-environment") + derUTF8("development"))
  let getTaskAllow = derSequence(derUTF8("get-task-allow") + Data([0x01, 0x01, 0xFF]))
  let keychainGroups = derSequence(
    derUTF8("keychain-access-groups") + derSequence(derUTF8("TEAMID1234.*")))
  let nested = derSequence(
    derUTF8("nested")
      + derNode(
        identifier: 0xB0,
        payload: derSequence(derUTF8("enabled") + Data([0x01, 0x01, 0x00]))))
  let version = derSequence(derUTF8("version") + Data([0x02, 0x01, 0x2A]))
  let dictionary = derNode(
    identifier: 0xB0,
    payload: apsEnvironment + getTaskAllow + keychainGroups + nested + version)
  return derNode(identifier: 0x70, payload: Data([0x02, 0x01, 0x01]) + dictionary)
}

private func derUTF8(_ value: String) -> Data {
  derNode(identifier: 0x0C, payload: Data(value.utf8))
}

private func derSequence(_ payload: Data) -> Data {
  derNode(identifier: 0x30, payload: payload)
}

private func derNode(identifier: UInt8, payload: Data) -> Data {
  precondition(payload.count < 256)
  let length =
    payload.count < 128
    ? Data([UInt8(payload.count)]) : Data([0x81, UInt8(payload.count)])
  return Data([identifier]) + length + payload
}

private func codeDirectory(
  codeLimit: Int,
  codeHashes: [Data],
  specialSlots: [UInt32: Data]
) -> Data {
  let identifier = Data("net.example.fixture\0".utf8)
  let team = Data("TEAMID1234\0".utf8)
  let headerSize = 88
  let identifierOffset = headerSize
  let teamOffset = identifierOffset + identifier.count
  let specialStart = teamOffset + team.count
  let specialSlotCount = Int(specialSlots.keys.max() ?? 0)
  let hashOffset = specialStart + specialSlotCount * 32
  let length = hashOffset + codeHashes.count * 32

  var result = Data()
  result.append(be32(0xFADE_0C02))
  result.append(be32(UInt32(length)))
  result.append(be32(0x0002_0400))
  result.append(be32(0))
  result.append(be32(UInt32(hashOffset)))
  result.append(be32(UInt32(identifierOffset)))
  result.append(be32(UInt32(specialSlotCount)))
  result.append(be32(UInt32(codeHashes.count)))
  result.append(be32(UInt32(codeLimit)))
  result.append(contentsOf: [32, 2, 0, 12])
  result.append(be32(0))
  result.append(be32(0))
  result.append(be32(UInt32(teamOffset)))
  result.append(be32(0))
  result.append(be64(UInt64(codeLimit)))
  result.append(be64(0))
  result.append(be64(UInt64(codeLimit)))
  result.append(be64(1))
  precondition(result.count == headerSize)
  result.append(identifier)
  result.append(team)
  for slot in stride(from: specialSlotCount, through: 1, by: -1) {
    result.append(specialSlots[UInt32(slot)] ?? Data(repeating: 0, count: 32))
  }
  for hash in codeHashes {
    result.append(hash)
  }
  precondition(result.count == length)
  return result
}

private func superBlob(_ blobs: [(UInt32, Data)]) -> Data {
  let indexSize = 12 + blobs.count * 8
  let length = indexSize + blobs.reduce(0) { $0 + $1.1.count }
  var result = Data()
  result.append(be32(0xFADE_0CC0))
  result.append(be32(UInt32(length)))
  result.append(be32(UInt32(blobs.count)))
  var offset = indexSize
  for (slot, data) in blobs {
    result.append(be32(slot))
    result.append(be32(UInt32(offset)))
    offset += data.count
  }
  for (_, data) in blobs {
    result.append(data)
  }
  return result
}

private func blob(magic: UInt32, payload: Data) -> Data {
  be32(magic) + be32(UInt32(8 + payload.count)) + payload
}

private func digest(_ data: Data) -> Data {
  Data(SHA256.hash(data: data))
}

private func le32(_ value: UInt32) -> Data {
  withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func le64(_ value: UInt64) -> Data {
  withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

private func segmentName(_ value: String) -> Data {
  var data = Data(value.utf8)
  data.append(Data(repeating: 0, count: 16 - data.count))
  return data
}

private func be32(_ value: UInt32) -> Data {
  withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

private func be64(_ value: UInt64) -> Data {
  withUnsafeBytes(of: value.bigEndian) { Data($0) }
}
