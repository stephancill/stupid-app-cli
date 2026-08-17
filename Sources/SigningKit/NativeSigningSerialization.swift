import CoreFoundation
import Foundation

public enum NativeSigningSerialization {
  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case unsupported(String)
    case malformed(String)

    public var description: String {
      switch self {
      case .unsupported(let detail): return "Unsupported native signing value: \(detail)."
      case .malformed(let detail): return "Malformed native signing value: \(detail)."
      }
    }
  }

  public static func entitlementDER(_ dictionary: [String: Any]) throws -> Data {
    NativeDER.node(0x70, NativeDER.integer(1) + (try derDictionary(dictionary)))
  }

  public static func requirementSet(identifier: String, leafCommonName: String) throws -> Data {
    guard !identifier.isEmpty, !leafCommonName.isEmpty else {
      throw Error.malformed("requirement identity is empty")
    }
    let wwdrOID = Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x63, 0x64, 0x06, 0x02, 0x01])
    let expression = and(
      opcode(2) + requirementData(Data(identifier.utf8)),
      and(
        opcode(15),
        and(
          opcode(11) + be32(0) + requirementData(Data("subject.CN".utf8)) + opcode(1)
            + requirementData(Data(leafCommonName.utf8)),
          opcode(14) + be32(1) + requirementData(wwdrOID) + opcode(0))))
    let requirement = blob(magic: 0xFADE_0C00, payload: be32(1) + expression)
    return blob(magic: 0xFADE_0C01, payload: be32(1) + be32(3) + be32(20) + requirement)
  }

  private static func derDictionary(_ dictionary: [String: Any]) throws -> Data {
    var entries = Data()
    for key in dictionary.keys.sorted(by: { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }
    ) {
      guard !key.isEmpty, let value = dictionary[key] else {
        throw Error.malformed("entitlement dictionary key is empty")
      }
      entries += NativeDER.sequence([NativeDER.utf8(key), try derValue(value)])
    }
    return NativeDER.node(0xB0, entries)
  }

  private static func derValue(_ value: Any) throws -> Data {
    switch value {
    case let value as String: return NativeDER.utf8(value)
    case let value as NSNumber:
      if CFGetTypeID(value) == CFBooleanGetTypeID() { return NativeDER.boolean(value.boolValue) }
      guard let integer = Int64(value.stringValue) else {
        throw Error.unsupported("non-integer number")
      }
      return NativeDER.integer(integer)
    case let value as [Any]: return NativeDER.sequence(try value.map(derValue))
    case let value as [String: Any]: return try derDictionary(value)
    default: throw Error.unsupported("entitlement plist type \(type(of: value))")
    }
  }

  private static func and(_ lhs: Data, _ rhs: Data) -> Data { opcode(6) + lhs + rhs }
  private static func opcode(_ value: UInt32) -> Data { be32(value) }
  private static func requirementData(_ data: Data) -> Data {
    be32(UInt32(data.count)) + data + Data(repeating: 0, count: (4 - data.count % 4) % 4)
  }
  private static func blob(magic: UInt32, payload: Data) -> Data {
    be32(magic) + be32(UInt32(payload.count + 8)) + payload
  }
  private static func be32(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
  }
}
