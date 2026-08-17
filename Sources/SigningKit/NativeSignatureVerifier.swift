import CoreFoundation
import Crypto
import Foundation
import SwiftASN1

/// Read-only parser and verifier for the narrow signature shape accepted by the native
/// signing spike: one thin, little-endian ARM64 executable with a SHA-256 CodeDirectory.
public enum NativeSignatureVerifier {
  public indirect enum EntitlementValue: Equatable, Sendable {
    case array([EntitlementValue])
    case dictionary([String: EntitlementValue])
    case boolean(Bool)
    case integer(Int64)
    case string(String)
  }

  public enum RequirementMatch: Equatable, Sendable {
    case exists
    case equal(Data)
  }

  public indirect enum RequirementExpression: Equatable, Sendable {
    case identifier(String)
    case anchorApple
    case anchorAppleGeneric
    case and(RequirementExpression, RequirementExpression)
    case certificateField(slot: Int32, field: String, match: RequirementMatch)
    case certificateGeneric(slot: Int32, oid: Data, match: RequirementMatch)
  }

  public struct Blob: Equatable, Sendable {
    public let slot: UInt32
    public let magic: UInt32
    public let data: Data
  }

  public struct CodeDirectory: Equatable, Sendable {
    public let version: UInt32
    public let flags: UInt32
    public let codeLimit: UInt64
    public let pageSize: Int
    public let identifier: String
    public let teamIdentifier: String?
    public let codeHashes: [Data]
    public let specialHashes: [UInt32: Data]
    public let executableSegmentFlags: UInt64
  }

  public struct Signature: Equatable, Sendable {
    public let signatureOffset: Int
    public let signatureSize: Int
    public let blobs: [Blob]
    public let codeDirectory: CodeDirectory
    public let entitlements: [String: EntitlementValue]
    public let designatedRequirement: RequirementExpression
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case unsupported(String)
    case malformed(String)
    case codePageMismatch(Int)
    case specialSlotMismatch(UInt32)
    case specialSlotContentMissing(UInt32)
    case entitlementMismatch
    case requirementMismatch(String)

    public var description: String {
      switch self {
      case .unsupported(let detail):
        return "Unsupported native signature input: \(detail)."
      case .malformed(let detail):
        return "Malformed native signature input: \(detail)."
      case .codePageMismatch(let index):
        return "Native signature verification failed for code page \(index)."
      case .specialSlotMismatch(let slot):
        return "Native signature verification failed for special slot \(slot)."
      case .specialSlotContentMissing(let slot):
        return "Native signature verification requires external content for special slot \(slot)."
      case .entitlementMismatch:
        return "Native signature verification failed because XML and DER entitlements differ."
      case .requirementMismatch(let detail):
        return "Native signature verification failed for the designated requirement: \(detail)."
      }
    }
  }

  private static let machO64LittleEndianMagic: UInt32 = 0xFEED_FACF
  private static let cpuTypeARM64: UInt32 = 0x0100_000C
  private static let machOExecutable: UInt32 = 2
  private static let loadCommandCodeSignature: UInt32 = 0x1D
  private static let embeddedSignatureMagic: UInt32 = 0xFADE_0CC0
  private static let codeDirectoryMagic: UInt32 = 0xFADE_0C02
  private static let requirementMagic: UInt32 = 0xFADE_0C00
  private static let sha256Type: UInt8 = 2
  private static let sha256Size: UInt8 = 32
  private static let blobHeaderSize = 8
  private static let xmlEntitlementsSlot: UInt32 = 5
  private static let derEntitlementsSlot: UInt32 = 7
  private static let requirementSetSlot: UInt32 = 2
  private static let designatedRequirementFlavor: UInt32 = 3
  private static let maximumRequirementDepth = 32
  private static let maximumRequirementNodes = 128
  private static let applicationPlistIdentifier = ASN1Identifier(
    tagWithNumber: 16, tagClass: .application)
  private static let dictionaryIdentifier = ASN1Identifier(
    tagWithNumber: 16, tagClass: .contextSpecific)

  /// Parses and verifies hashes stored in an executable's CodeDirectory. This does
  /// not authenticate the CodeDirectory; CMS verification is a separate spike gate.
  /// `externalSpecialSlots` supplies content not embedded in the SuperBlob, notably
  /// `Info.plist` (slot 1) and `_CodeSignature/CodeResources` (slot 3).
  public static func verifyCodeDirectoryHashes(
    executable: Data,
    externalSpecialSlots: [UInt32: Data] = [:]
  ) throws -> Signature {
    let executable = Data(executable)
    let signature = try parse(executable: executable)
    let codeDirectory = signature.codeDirectory

    guard codeDirectory.codeLimit == UInt64(signature.signatureOffset) else {
      throw Error.malformed("CodeDirectory code limit does not match LC_CODE_SIGNATURE")
    }

    let codeLimit = signature.signatureOffset
    let expectedCodeSlots = (codeLimit + codeDirectory.pageSize - 1) / codeDirectory.pageSize
    guard codeDirectory.codeHashes.count == expectedCodeSlots else {
      throw Error.malformed("CodeDirectory code-slot count does not match its code limit")
    }

    for index in 0..<expectedCodeSlots {
      let start = index * codeDirectory.pageSize
      let end = min(start + codeDirectory.pageSize, codeLimit)
      let digest = sha256(executable.subdata(in: start..<end))
      guard digest == codeDirectory.codeHashes[index] else {
        throw Error.codePageMismatch(index)
      }
    }

    let embeddedSlots = Dictionary(uniqueKeysWithValues: signature.blobs.map { ($0.slot, $0.data) })
    let zeroHash = Data(repeating: 0, count: Int(sha256Size))
    for slot in externalSpecialSlots.keys where codeDirectory.specialHashes[slot] == nil {
      throw Error.malformed("external special slot is missing its CodeDirectory hash")
    }
    for (slot, expectedHash) in codeDirectory.specialHashes.sorted(by: { $0.key < $1.key }) {
      if let content = embeddedSlots[slot] ?? externalSpecialSlots[slot] {
        guard sha256(content) == expectedHash else {
          throw Error.specialSlotMismatch(slot)
        }
      } else if expectedHash != zeroHash {
        throw Error.specialSlotContentMissing(slot)
      }
    }

    for blob in signature.blobs where blob.slot > 0 && blob.slot < 32 {
      guard codeDirectory.specialHashes[blob.slot] != nil else {
        throw Error.malformed("embedded special slot is missing its CodeDirectory hash")
      }
    }

    return signature
  }

  public static func verifyCMS(
    executable: Data,
    trustedRootCertificatesPEM: [String]
  ) throws -> NativeCMS.VerificationResult {
    let signature = try parse(executable: executable)
    guard let codeDirectory = signature.blobs.first(where: { $0.slot == 0 }),
      let cms = signature.blobs.first(where: { $0.slot == 0x1_0000 }), cms.data.count >= 8
    else { throw Error.malformed("CodeDirectory or CMS slot is missing") }
    let result = try NativeCMS.verify(
      cms: cms.data.subdata(in: 8..<cms.data.count),
      codeDirectory: codeDirectory.data,
      trustedRootCertificatesPEM: trustedRootCertificatesPEM)
    try evaluateRequirement(signature.designatedRequirement, certificates: result)
    return result
  }

  private static func evaluateRequirement(
    _ expression: RequirementExpression,
    certificates: NativeCMS.VerificationResult
  ) throws {
    switch expression {
    case .identifier:
      return
    case .anchorApple, .anchorAppleGeneric:
      return  // CMS chain verification established the explicitly supplied trust anchor.
    case .and(let lhs, let rhs):
      try evaluateRequirement(lhs, certificates: certificates)
      try evaluateRequirement(rhs, certificates: certificates)
    case .certificateField(let slot, let field, let match):
      guard slot >= 0, Int(slot) < certificates.certificateCount, field == "subject.CN" else {
        throw Error.requirementMismatch(
          "certificate field predicate is outside the supported chain")
      }
      let commonName = certificates.certificateCommonNames[Int(slot)].map { Data($0.utf8) }
      guard requirementMatch(match, value: commonName) else {
        throw Error.requirementMismatch("certificate common-name predicate did not match")
      }
    case .certificateGeneric(let slot, let oid, let match):
      guard slot >= 0, Int(slot) < certificates.certificateCount else {
        throw Error.requirementMismatch("certificate extension slot is outside the chain")
      }
      let dotted: String
      do { dotted = try NativeCMS.oidString(content: oid) } catch {
        throw Error.requirementMismatch("certificate extension OID is malformed")
      }
      guard requirementMatch(match, value: certificates.certificateExtensions[Int(slot)][dotted])
      else {
        throw Error.requirementMismatch("certificate extension predicate did not match")
      }
    }
  }

  private static func requirementMatch(_ match: RequirementMatch, value: Data?) -> Bool {
    switch match {
    case .exists: return value != nil
    case .equal(let expected): return value == expected
    }
  }

  public static func parse(executable: Data) throws -> Signature {
    let executable = Data(executable)
    guard executable.count >= 32 else {
      throw Error.malformed("Mach-O header is truncated")
    }
    guard try readUInt32LE(executable, at: 0) == machO64LittleEndianMagic else {
      throw Error.unsupported("expected a thin little-endian 64-bit Mach-O")
    }
    guard try readUInt32LE(executable, at: 4) == cpuTypeARM64 else {
      throw Error.unsupported("expected ARM64 CPU type")
    }
    guard try readUInt32LE(executable, at: 12) == machOExecutable else {
      throw Error.unsupported("expected MH_EXECUTE file type")
    }

    let commandCount = try int(try readUInt32LE(executable, at: 16), field: "load-command count")
    let commandBytes = try int(try readUInt32LE(executable, at: 20), field: "load-command size")
    let commandsEnd = try adding(32, commandBytes, field: "load-command range")
    guard commandsEnd <= executable.count else {
      throw Error.malformed("load commands exceed the executable")
    }

    var commandOffset = 32
    var codeSignature: (offset: Int, size: Int)?
    var linkedit: (offset: Int, size: Int)?
    for _ in 0..<commandCount {
      guard commandOffset <= commandsEnd - 8 else {
        throw Error.malformed("load-command header is truncated")
      }
      let command = try readUInt32LE(executable, at: commandOffset)
      let commandSize = try int(
        try readUInt32LE(executable, at: commandOffset + 4), field: "load-command size")
      guard commandSize >= 8, commandSize.isMultiple(of: 8) else {
        throw Error.malformed("load-command size is invalid")
      }
      let nextOffset = try adding(commandOffset, commandSize, field: "load-command range")
      guard nextOffset <= commandsEnd else {
        throw Error.malformed("load command exceeds the declared command area")
      }

      if command == loadCommandCodeSignature {
        guard commandSize == 16 else {
          throw Error.malformed("LC_CODE_SIGNATURE has an invalid size")
        }
        guard codeSignature == nil else {
          throw Error.malformed("multiple LC_CODE_SIGNATURE commands are unsupported")
        }
        codeSignature = (
          try int(try readUInt32LE(executable, at: commandOffset + 8), field: "signature offset"),
          try int(try readUInt32LE(executable, at: commandOffset + 12), field: "signature size")
        )
      } else if command == 0x19 {
        guard commandSize >= 72 else {
          throw Error.malformed("LC_SEGMENT_64 is truncated")
        }
        let segmentName = try readSegmentName(executable, at: commandOffset + 8)
        if segmentName == "__LINKEDIT" {
          guard linkedit == nil else {
            throw Error.malformed("multiple __LINKEDIT segments are unsupported")
          }
          linkedit = (
            try int(
              try readUInt64LE(executable, at: commandOffset + 40), field: "__LINKEDIT offset"),
            try int(
              try readUInt64LE(executable, at: commandOffset + 48), field: "__LINKEDIT size")
          )
        }
      }
      commandOffset = nextOffset
    }
    guard commandOffset == commandsEnd else {
      throw Error.malformed("load-command count does not consume the declared command area")
    }
    guard let codeSignature else {
      throw Error.malformed("LC_CODE_SIGNATURE is missing")
    }
    guard let linkedit else {
      throw Error.malformed("__LINKEDIT segment is missing")
    }
    let signatureEnd = try adding(
      codeSignature.offset, codeSignature.size, field: "signature range")
    let linkeditEnd = try adding(linkedit.offset, linkedit.size, field: "__LINKEDIT range")
    guard
      linkedit.offset >= commandsEnd,
      codeSignature.offset >= linkedit.offset,
      signatureEnd == linkeditEnd,
      linkeditEnd == executable.count
    else {
      throw Error.unsupported("embedded signature must be the final executable data")
    }

    let signatureData = executable.subdata(in: codeSignature.offset..<signatureEnd)
    let blobs = try parseSuperBlob(signatureData)
    guard let codeDirectoryBlob = blobs.first(where: { $0.slot == 0 }) else {
      throw Error.malformed("primary CodeDirectory slot is missing")
    }
    let codeDirectory = try parseCodeDirectory(codeDirectoryBlob.data)
    let designatedRequirement = try parseDesignatedRequirement(
      blobs, codeIdentifier: codeDirectory.identifier)
    let entitlements = try parseAndCompareEntitlements(blobs)
    return Signature(
      signatureOffset: codeSignature.offset,
      signatureSize: codeSignature.size,
      blobs: blobs,
      codeDirectory: codeDirectory,
      entitlements: entitlements,
      designatedRequirement: designatedRequirement
    )
  }

  private static func parseDesignatedRequirement(
    _ blobs: [Blob],
    codeIdentifier: String
  ) throws -> RequirementExpression {
    guard let set = blobs.first(where: { $0.slot == requirementSetSlot }) else {
      throw Error.malformed("RequirementSet slot is missing")
    }
    let data = set.data
    guard data.count >= 20 else {
      throw Error.malformed("RequirementSet is truncated")
    }
    let count = try readUInt32BE(data, at: 8)
    guard count == 1 else {
      throw Error.unsupported("expected exactly one designated requirement")
    }
    guard try readUInt32BE(data, at: 12) == designatedRequirementFlavor else {
      throw Error.unsupported("RequirementSet contains a non-designated flavor")
    }
    let requirementOffset = try int(
      try readUInt32BE(data, at: 16), field: "designated requirement offset")
    guard requirementOffset >= 20, requirementOffset <= data.count - blobHeaderSize else {
      throw Error.malformed("designated requirement offset is out of bounds")
    }
    guard try readUInt32BE(data, at: requirementOffset) == requirementMagic else {
      throw Error.malformed("designated requirement has invalid magic")
    }
    let requirementLength = try int(
      try readUInt32BE(data, at: requirementOffset + 4), field: "designated requirement length")
    guard requirementLength >= 16,
      try adding(requirementOffset, requirementLength, field: "designated requirement range")
        == data.count
    else {
      throw Error.malformed("designated requirement length is invalid")
    }

    var cursor = RequirementCursor(
      data: data.subdata(in: (requirementOffset + blobHeaderSize)..<data.count))
    guard try cursor.readUInt32(field: "requirement expression count") == 1 else {
      throw Error.unsupported("expected one designated requirement expression")
    }
    var nodeCount = 0
    let expression = try parseRequirementExpression(
      cursor: &cursor, depth: 0, nodeCount: &nodeCount)
    guard cursor.isAtEnd else {
      throw Error.malformed("designated requirement contains trailing data")
    }
    let identifiers = requirementIdentifiers(in: expression)
    guard identifiers == [codeIdentifier] else {
      throw Error.malformed("designated requirement identifier does not match CodeDirectory")
    }
    return expression
  }

  private static func parseRequirementExpression(
    cursor: inout RequirementCursor,
    depth: Int,
    nodeCount: inout Int
  ) throws -> RequirementExpression {
    guard depth < maximumRequirementDepth else {
      throw Error.unsupported("designated requirement expression is too deeply nested")
    }
    nodeCount += 1
    guard nodeCount <= maximumRequirementNodes else {
      throw Error.unsupported("designated requirement expression has too many nodes")
    }
    let rawOpcode = try cursor.readUInt32(field: "requirement opcode")
    guard rawOpcode & 0xFF00_0000 == 0 else {
      throw Error.unsupported("requirement opcode flags are unsupported")
    }
    switch rawOpcode {
    case 2:
      let data = try cursor.readData(field: "requirement identifier")
      guard let identifier = String(data: data, encoding: .utf8), !identifier.isEmpty else {
        throw Error.malformed("requirement identifier is not valid UTF-8")
      }
      return .identifier(identifier)
    case 3:
      return .anchorApple
    case 6:
      let lhs = try parseRequirementExpression(
        cursor: &cursor, depth: depth + 1, nodeCount: &nodeCount)
      let rhs = try parseRequirementExpression(
        cursor: &cursor, depth: depth + 1, nodeCount: &nodeCount)
      return .and(lhs, rhs)
    case 11:
      let slot = Int32(bitPattern: try cursor.readUInt32(field: "certificate field slot"))
      let fieldData = try cursor.readData(field: "certificate field name")
      guard let field = String(data: fieldData, encoding: .utf8), !field.isEmpty else {
        throw Error.malformed("certificate field name is not valid UTF-8")
      }
      return .certificateField(
        slot: slot, field: field, match: try parseRequirementMatch(cursor: &cursor))
    case 14:
      let slot = Int32(bitPattern: try cursor.readUInt32(field: "certificate generic slot"))
      let oid = try cursor.readData(field: "certificate generic OID")
      guard !oid.isEmpty else {
        throw Error.malformed("certificate generic OID is empty")
      }
      return .certificateGeneric(
        slot: slot, oid: oid, match: try parseRequirementMatch(cursor: &cursor))
    case 15:
      return .anchorAppleGeneric
    default:
      throw Error.unsupported("requirement opcode \(rawOpcode) is outside the signing scope")
    }
  }

  private static func parseRequirementMatch(cursor: inout RequirementCursor) throws
    -> RequirementMatch
  {
    switch try cursor.readUInt32(field: "requirement match opcode") {
    case 0:
      return .exists
    case 1:
      return .equal(try cursor.readData(field: "requirement match value"))
    case let opcode:
      throw Error.unsupported("requirement match opcode \(opcode) is outside the signing scope")
    }
  }

  private static func requirementIdentifiers(in expression: RequirementExpression) -> [String] {
    switch expression {
    case .identifier(let value):
      return [value]
    case .and(let lhs, let rhs):
      return requirementIdentifiers(in: lhs) + requirementIdentifiers(in: rhs)
    default:
      return []
    }
  }

  private static func parseAndCompareEntitlements(_ blobs: [Blob]) throws
    -> [String: EntitlementValue]
  {
    guard let xmlBlob = blobs.first(where: { $0.slot == xmlEntitlementsSlot }) else {
      throw Error.malformed("XML entitlements slot is missing")
    }
    guard let derBlob = blobs.first(where: { $0.slot == derEntitlementsSlot }) else {
      throw Error.malformed("DER entitlements slot is missing")
    }
    let xml = try parseXMLEntitlements(blob: xmlBlob.data)
    let der = try parseDEREntitlements(blob: derBlob.data)
    guard xml == der else {
      throw Error.entitlementMismatch
    }
    return xml
  }

  private static func parseXMLEntitlements(blob: Data) throws -> [String: EntitlementValue] {
    let payload = try blobPayload(blob, field: "XML entitlements")
    let object: Any
    do {
      object = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil)
    } catch {
      throw Error.malformed("XML entitlements plist is invalid")
    }
    guard let dictionary = object as? [String: Any] else {
      throw Error.malformed("XML entitlements root is not a dictionary")
    }
    return try dictionary.mapValues { try entitlementValue(fromPropertyList: $0) }
  }

  private static func entitlementValue(fromPropertyList value: Any) throws -> EntitlementValue {
    switch value {
    case let value as String:
      return .string(value)
    case let value as NSNumber:
      if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return .boolean(value.boolValue)
      }
      guard let integer = Int64(value.stringValue) else {
        throw Error.unsupported("entitlement plist contains a non-integer number")
      }
      return .integer(integer)
    case let value as [Any]:
      return .array(try value.map(entitlementValue(fromPropertyList:)))
    case let value as [String: Any]:
      return .dictionary(try value.mapValues { try entitlementValue(fromPropertyList: $0) })
    default:
      throw Error.unsupported("entitlement plist contains an unsupported value type")
    }
  }

  private static func parseDEREntitlements(blob: Data) throws -> [String: EntitlementValue] {
    let payload = try blobPayload(blob, field: "DER entitlements")
    let root: ASN1Node
    do {
      root = try DER.parse(Array(payload))
    } catch {
      throw Error.malformed("DER entitlements payload is invalid")
    }
    guard root.identifier == applicationPlistIdentifier,
      case .constructed(let rootChildren) = root.content
    else {
      throw Error.malformed("DER entitlements root has an invalid type")
    }
    var children = rootChildren.makeIterator()
    guard let versionNode = children.next() else {
      throw Error.malformed("DER entitlements version is missing")
    }
    let version: Int64
    do {
      version = try Int64(derEncoded: versionNode)
    } catch {
      throw Error.malformed("DER entitlements version is invalid")
    }
    guard version == 1 else {
      throw Error.unsupported("DER entitlements version is not 1")
    }
    guard let dictionaryNode = children.next(), children.next() == nil else {
      throw Error.malformed("DER entitlements root has an invalid field count")
    }
    return try parseDERDictionary(dictionaryNode)
  }

  private static func parseDERDictionary(_ node: ASN1Node) throws
    -> [String: EntitlementValue]
  {
    guard node.identifier == dictionaryIdentifier, case .constructed(let entries) = node.content
    else {
      throw Error.malformed("DER entitlement dictionary has an invalid type")
    }
    var result = [String: EntitlementValue]()
    var previousKey: String?
    for entry in entries {
      guard entry.identifier == .sequence, case .constructed(let fields) = entry.content else {
        throw Error.malformed("DER entitlement dictionary entry has an invalid type")
      }
      var iterator = fields.makeIterator()
      guard let keyNode = iterator.next(), let valueNode = iterator.next(), iterator.next() == nil
      else {
        throw Error.malformed("DER entitlement dictionary entry has an invalid field count")
      }
      let key = try parseDERString(keyNode, field: "dictionary key")
      guard !key.isEmpty else {
        throw Error.malformed("DER entitlement dictionary key is empty")
      }
      if let previousKey, key <= previousKey {
        throw Error.malformed("DER entitlement dictionary keys are not strictly ordered")
      }
      previousKey = key
      result[key] = try parseDERValue(valueNode)
    }
    return result
  }

  private static func parseDERValue(_ node: ASN1Node) throws -> EntitlementValue {
    do {
      switch node.identifier {
      case .sequence:
        guard case .constructed(let children) = node.content else {
          throw Error.malformed("DER entitlement array is not constructed")
        }
        return .array(try children.map(parseDERValue))
      case dictionaryIdentifier:
        return .dictionary(try parseDERDictionary(node))
      case .boolean:
        return .boolean(try Bool(derEncoded: node))
      case .integer:
        return .integer(try Int64(derEncoded: node))
      case .utf8String:
        return .string(try parseDERString(node, field: "string value"))
      default:
        throw Error.unsupported("DER entitlement contains an unsupported value type")
      }
    } catch let error as Error {
      throw error
    } catch {
      throw Error.malformed("DER entitlement value is invalid")
    }
  }

  private static func parseDERString(_ node: ASN1Node, field: String) throws -> String {
    guard node.identifier == .utf8String, case .primitive(let bytes) = node.content,
      let value = String(bytes: bytes, encoding: .utf8)
    else {
      throw Error.malformed("DER entitlement \(field) is invalid")
    }
    return value
  }

  private static func blobPayload(_ blob: Data, field: String) throws -> Data {
    guard blob.count >= blobHeaderSize else {
      throw Error.malformed("\(field) blob is truncated")
    }
    return blob.subdata(in: blobHeaderSize..<blob.count)
  }

  private static func parseSuperBlob(_ data: Data) throws -> [Blob] {
    guard data.count >= 12 else {
      throw Error.malformed("embedded-signature SuperBlob is truncated")
    }
    guard try readUInt32BE(data, at: 0) == embeddedSignatureMagic else {
      throw Error.malformed("embedded-signature SuperBlob has invalid magic")
    }
    let declaredLength = try int(try readUInt32BE(data, at: 4), field: "SuperBlob length")
    let count = try int(try readUInt32BE(data, at: 8), field: "SuperBlob count")
    guard declaredLength >= 12, declaredLength <= data.count else {
      throw Error.malformed("SuperBlob length is out of bounds")
    }
    let indexBytes = try multiplying(count, 8, field: "SuperBlob index size")
    let payloadStart = try adding(12, indexBytes, field: "SuperBlob index range")
    guard payloadStart <= declaredLength else {
      throw Error.malformed("SuperBlob index exceeds its declared length")
    }

    var blobs = [Blob]()
    var slots = Set<UInt32>()
    var ranges = [Range<Int>]()
    for index in 0..<count {
      let indexOffset = 12 + index * 8
      let slot = try readUInt32BE(data, at: indexOffset)
      let blobOffset = try int(try readUInt32BE(data, at: indexOffset + 4), field: "blob offset")
      guard slots.insert(slot).inserted else {
        throw Error.malformed("SuperBlob contains a duplicate slot")
      }
      guard blobOffset >= payloadStart, blobOffset <= declaredLength - 8 else {
        throw Error.malformed("blob offset is out of bounds")
      }
      let magic = try readUInt32BE(data, at: blobOffset)
      let blobLength = try int(try readUInt32BE(data, at: blobOffset + 4), field: "blob length")
      guard blobLength >= 8 else {
        throw Error.malformed("blob length is invalid")
      }
      let blobEnd = try adding(blobOffset, blobLength, field: "blob range")
      guard blobEnd <= declaredLength else {
        throw Error.malformed("blob exceeds the SuperBlob")
      }
      let range = blobOffset..<blobEnd
      guard !ranges.contains(where: { $0.overlaps(range) }) else {
        throw Error.malformed("SuperBlob entries overlap")
      }
      ranges.append(range)
      blobs.append(Blob(slot: slot, magic: magic, data: data.subdata(in: range)))
    }

    guard blobs.first(where: { $0.slot == 0 })?.magic == codeDirectoryMagic else {
      throw Error.malformed("primary CodeDirectory slot has invalid magic")
    }
    let knownMagicBySlot: [UInt32: UInt32] = [
      2: 0xFADE_0C01,
      5: 0xFADE_7171,
      7: 0xFADE_7172,
      0x1_0000: 0xFADE_0B01,
    ]
    for blob in blobs {
      if let expectedMagic = knownMagicBySlot[blob.slot], blob.magic != expectedMagic {
        throw Error.malformed("known signature slot has invalid blob magic")
      }
    }
    return blobs
  }

  private static func parseCodeDirectory(_ data: Data) throws -> CodeDirectory {
    guard data.count >= 44 else {
      throw Error.malformed("CodeDirectory header is truncated")
    }
    guard try readUInt32BE(data, at: 0) == codeDirectoryMagic else {
      throw Error.malformed("CodeDirectory has invalid magic")
    }
    let declaredLength = try int(try readUInt32BE(data, at: 4), field: "CodeDirectory length")
    guard declaredLength == data.count else {
      throw Error.malformed("CodeDirectory length does not match its blob")
    }

    let version = try readUInt32BE(data, at: 8)
    guard (0x0002_0000...0x0002_0600).contains(version) else {
      throw Error.unsupported("CodeDirectory version is outside the audited range")
    }
    let minimumHeaderLength: Int
    switch version {
    case 0x0002_0000..<0x0002_0100: minimumHeaderLength = 44
    case 0x0002_0100..<0x0002_0200: minimumHeaderLength = 48
    case 0x0002_0200..<0x0002_0300: minimumHeaderLength = 52
    case 0x0002_0300..<0x0002_0400: minimumHeaderLength = 64
    case 0x0002_0400..<0x0002_0500: minimumHeaderLength = 88
    case 0x0002_0500..<0x0002_0600: minimumHeaderLength = 96
    default: minimumHeaderLength = 108
    }
    guard data.count >= minimumHeaderLength else {
      throw Error.malformed("CodeDirectory versioned header is truncated")
    }

    let hashOffset = try int(try readUInt32BE(data, at: 16), field: "hash offset")
    let identifierOffset = try int(try readUInt32BE(data, at: 20), field: "identifier offset")
    let specialSlotCount = try int(try readUInt32BE(data, at: 24), field: "special-slot count")
    let codeSlotCount = try int(try readUInt32BE(data, at: 28), field: "code-slot count")
    let codeLimit32 = try readUInt32BE(data, at: 32)
    let hashSize = try readByte(data, at: 36)
    let hashType = try readByte(data, at: 37)
    let pageExponent = try readByte(data, at: 39)
    guard hashType == sha256Type, hashSize == sha256Size else {
      throw Error.unsupported("only full SHA-256 CodeDirectory hashes are supported")
    }
    guard pageExponent == 12 else {
      throw Error.unsupported("only 4 KiB CodeDirectory pages are supported")
    }
    if version >= 0x0002_0100, try readUInt32BE(data, at: 44) != 0 {
      throw Error.unsupported("scatter CodeDirectories are unsupported")
    }

    let teamOffset: Int?
    if version >= 0x0002_0200 {
      let value = try int(try readUInt32BE(data, at: 48), field: "team offset")
      teamOffset = value == 0 ? nil : value
    } else {
      teamOffset = nil
    }

    let codeLimit: UInt64
    if version >= 0x0002_0300 {
      let codeLimit64 = try readUInt64BE(data, at: 56)
      codeLimit = codeLimit64 == 0 ? UInt64(codeLimit32) : codeLimit64
    } else {
      codeLimit = UInt64(codeLimit32)
    }
    guard codeLimit <= UInt64(Int.max) else {
      throw Error.malformed("CodeDirectory code limit is too large")
    }

    let identifier = try readCString(
      data, at: identifierOffset, minimumOffset: minimumHeaderLength, field: "identifier")
    let teamIdentifier = try teamOffset.map {
      try readCString(data, at: $0, minimumOffset: minimumHeaderLength, field: "team identifier")
    }

    let specialHashBytes = try multiplying(
      specialSlotCount, Int(hashSize), field: "special hash table")
    guard hashOffset >= specialHashBytes else {
      throw Error.malformed("special hash table underflows the CodeDirectory")
    }
    let specialStart = hashOffset - specialHashBytes
    let codeHashBytes = try multiplying(codeSlotCount, Int(hashSize), field: "code hash table")
    let hashesEnd = try adding(hashOffset, codeHashBytes, field: "hash table")
    guard specialStart >= minimumHeaderLength, hashesEnd <= data.count else {
      throw Error.malformed("CodeDirectory hash table is out of bounds")
    }

    var specialHashes = [UInt32: Data]()
    for index in 0..<specialSlotCount {
      let start = specialStart + index * Int(hashSize)
      let slot = UInt32(specialSlotCount - index)
      specialHashes[slot] = data.subdata(in: start..<(start + Int(hashSize)))
    }
    var codeHashes = [Data]()
    for index in 0..<codeSlotCount {
      let start = hashOffset + index * Int(hashSize)
      codeHashes.append(data.subdata(in: start..<(start + Int(hashSize))))
    }

    return CodeDirectory(
      version: version,
      flags: try readUInt32BE(data, at: 12),
      codeLimit: codeLimit,
      pageSize: 1 << Int(pageExponent),
      identifier: identifier,
      teamIdentifier: teamIdentifier,
      codeHashes: codeHashes,
      specialHashes: specialHashes,
      executableSegmentFlags: version >= 0x0002_0400 ? try readUInt64BE(data, at: 80) : 0
    )
  }

  private static func sha256(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }

  private static func readCString(
    _ data: Data,
    at offset: Int,
    minimumOffset: Int,
    field: String
  ) throws -> String {
    guard offset >= minimumOffset, offset < data.count else {
      throw Error.malformed("CodeDirectory \(field) offset is out of bounds")
    }
    guard let end = data[offset...].firstIndex(of: 0) else {
      throw Error.malformed("CodeDirectory \(field) is not terminated")
    }
    guard let value = String(data: data[offset..<end], encoding: .utf8), !value.isEmpty else {
      throw Error.malformed("CodeDirectory \(field) is not valid UTF-8")
    }
    return value
  }

  private static func readByte(_ data: Data, at offset: Int) throws -> UInt8 {
    guard offset >= 0, offset < data.count else {
      throw Error.malformed("integer field is truncated")
    }
    return data[offset]
  }

  private static func readUInt32LE(_ data: Data, at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset <= data.count - 4 else {
      throw Error.malformed("32-bit field is truncated")
    }
    return data.withUnsafeBytes {
      $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
    }
  }

  private static func readUInt32BE(_ data: Data, at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset <= data.count - 4 else {
      throw Error.malformed("32-bit field is truncated")
    }
    return data.withUnsafeBytes {
      $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
    }
  }

  private static func readUInt64BE(_ data: Data, at offset: Int) throws -> UInt64 {
    guard offset >= 0, offset <= data.count - 8 else {
      throw Error.malformed("64-bit field is truncated")
    }
    return data.withUnsafeBytes {
      $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian
    }
  }

  private static func readUInt64LE(_ data: Data, at offset: Int) throws -> UInt64 {
    guard offset >= 0, offset <= data.count - 8 else {
      throw Error.malformed("64-bit field is truncated")
    }
    return data.withUnsafeBytes {
      $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
    }
  }

  private static func readSegmentName(_ data: Data, at offset: Int) throws -> String {
    guard offset >= 0, offset <= data.count - 16 else {
      throw Error.malformed("segment name is truncated")
    }
    let bytes = data.subdata(in: offset..<(offset + 16))
    let name = bytes.prefix(while: { $0 != 0 })
    guard let value = String(data: name, encoding: .ascii) else {
      throw Error.malformed("segment name is not ASCII")
    }
    return value
  }

  private static func int(_ value: UInt32, field: String) throws -> Int {
    guard let result = Int(exactly: value) else {
      throw Error.malformed("\(field) is too large")
    }
    return result
  }

  private static func int(_ value: UInt64, field: String) throws -> Int {
    guard let result = Int(exactly: value) else {
      throw Error.malformed("\(field) is too large")
    }
    return result
  }

  private static func adding(_ lhs: Int, _ rhs: Int, field: String) throws -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else {
      throw Error.malformed("\(field) overflows")
    }
    return result
  }

  private static func multiplying(_ lhs: Int, _ rhs: Int, field: String) throws -> Int {
    let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    guard !overflow else {
      throw Error.malformed("\(field) overflows")
    }
    return result
  }

  private struct RequirementCursor {
    let data: Data
    var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readUInt32(field: String) throws -> UInt32 {
      guard offset <= data.count - 4 else {
        throw Error.malformed("\(field) is truncated")
      }
      let value = data.withUnsafeBytes {
        $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
      }
      offset += 4
      return value
    }

    mutating func readData(field: String) throws -> Data {
      let length = try NativeSignatureVerifier.int(
        readUInt32(field: "\(field) length"), field: "\(field) length")
      let (end, overflow) = offset.addingReportingOverflow(length)
      guard !overflow, end <= data.count else {
        throw Error.malformed("\(field) exceeds the designated requirement")
      }
      let value = data.subdata(in: offset..<end)
      let remainder = length % 4
      let padding = remainder == 0 ? 0 : 4 - remainder
      let (paddedEnd, paddingOverflow) = end.addingReportingOverflow(padding)
      guard !paddingOverflow, paddedEnd <= data.count else {
        throw Error.malformed("\(field) padding is truncated")
      }
      guard data[end..<paddedEnd].allSatisfy({ $0 == 0 }) else {
        throw Error.malformed("\(field) padding is not zero")
      }
      offset = paddedEnd
      return value
    }
  }
}
