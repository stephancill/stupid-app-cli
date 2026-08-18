import Foundation

/// A typed value in Apple's RemoteXPC binary dictionary format.
public enum XPCValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case int64(Int64)
  case uint64(UInt64)
  case double(Double)
  case data(Data)
  case string(String)
  case uuid(UUID)
  case array([XPCValue])
  case dictionary([String: XPCValue])

  public var dictionaryValue: [String: XPCValue]? {
    if case .dictionary(let value) = self { return value }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var int64Value: Int64? {
    if case .int64(let value) = self { return value }
    return nil
  }

  public var uint64Value: UInt64? {
    if case .uint64(let value) = self { return value }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var dataValue: Data? {
    if case .data(let value) = self { return value }
    return nil
  }
}

/// Bounded encoder and decoder for the RemoteXPC binary dictionary format
/// used by remoted on iOS 17 and later.
enum XPCCodec {
  enum Error: Swift.Error, Equatable, CustomStringConvertible {
    case unsupportedValue(String)
    case truncated
    case malformed(String)
    case unknownType(UInt32)

    var description: String {
      switch self {
      case .unsupportedValue(let detail):
        return "The XPC value is unsupported: \(detail)."
      case .truncated:
        return "The XPC payload is truncated."
      case .malformed(let detail):
        return "The XPC payload is malformed: \(detail)."
      case .unknownType(let type):
        return "The XPC payload used an unsupported message type 0x\(String(type, radix: 16))."
      }
    }
  }

  enum MessageType: UInt32 {
    case null = 0x0000_1000
    case bool = 0x0000_2000
    case int64 = 0x0000_3000
    case uint64 = 0x0000_4000
    case double = 0x0000_5000
    case pointer = 0x0000_6000
    case date = 0x0000_7000
    case data = 0x0000_8000
    case string = 0x0000_9000
    case uuid = 0x0000_A000
    case fd = 0x0000_B000
    case shmem = 0x0000_C000
    case machSend = 0x0000_D000
    case array = 0x0000_E000
    case dictionary = 0x0000_F000
    case error = 0x0001_0000
    case fileTransfer = 0x0001_A000
  }

  static let payloadMagic: UInt32 = 0x4213_3742
  static let payloadProtocolVersion: UInt32 = 5
  static let wrapperMagic: UInt32 = 0x29B0_0B92

  // MARK: - Object encoding

  static func encodeObject(_ value: XPCValue) throws -> Data {
    let writer = Writer()
    try encodeObject(value, into: writer)
    return writer.data
  }

  private static func encodeObject(_ value: XPCValue, into writer: Writer) throws {
    switch value {
    case .null:
      writer.appendUInt32(MessageType.null.rawValue)
    case .bool(let bool):
      writer.appendUInt32(MessageType.bool.rawValue)
      writer.appendUInt32(bool ? 1 : 0)
    case .int64(let integer):
      writer.appendUInt32(MessageType.int64.rawValue)
      writer.appendUInt64(UInt64(bitPattern: integer))
    case .uint64(let integer):
      writer.appendUInt32(MessageType.uint64.rawValue)
      writer.appendUInt64(integer)
    case .double(let floating):
      writer.appendUInt32(MessageType.double.rawValue)
      writer.appendUInt64(floating.bitPattern.bigEndian)
    case .data(let bytes):
      writer.appendUInt32(MessageType.data.rawValue)
      try writeData(bytes, into: writer, trailingNull: false)
    case .string(let string):
      writer.appendUInt32(MessageType.string.rawValue)
      try writeData(Data(string.utf8), into: writer, trailingNull: true)
    case .uuid(let uuid):
      writer.appendUInt32(MessageType.uuid.rawValue)
      var bytes = Data(count: 16)
      withUnsafeBytes(of: uuid.uuid) { source in
        bytes.withUnsafeMutableBytes { destination in
          destination.copyBytes(from: source)
        }
      }
      writer.data.append(bytes)
    case .array(let entries):
      writer.appendUInt32(MessageType.array.rawValue)
      let inner = Writer()
      inner.appendUInt32(UInt32(entries.count))
      for entry in entries {
        try encodeObject(entry, into: inner)
      }
      writer.appendUInt32(UInt32(inner.data.count))
      writer.data.append(inner.data)
    case .dictionary(let entries):
      writer.appendUInt32(MessageType.dictionary.rawValue)
      let inner = Writer()
      inner.appendUInt32(UInt32(entries.count))
      for (key, entry) in entries.sorted(by: { $0.key < $1.key }) {
        var keyBytes = Data(key.utf8)
        keyBytes.append(0)
        inner.data.append(keyBytes)
        padToFour(&inner.data, relativeTo: keyBytes.count)
        try encodeObject(entry, into: inner)
      }
      writer.appendUInt32(UInt32(inner.data.count))
      writer.data.append(inner.data)
    }
  }

  private static func writeData(_ bytes: Data, into writer: Writer, trailingNull: Bool) throws {
    var payload = bytes
    if trailingNull { payload.append(0) }
    guard payload.count <= UInt32.max else {
      throw Error.unsupportedValue("data payload exceeds 4 GiB")
    }
    writer.appendUInt32(UInt32(payload.count))
    writer.data.append(payload)
    padToFour(&writer.data, relativeTo: payload.count)
  }

  private static func padToFour(_ data: inout Data, relativeTo length: Int) {
    let pad = (4 - (length % 4)) % 4
    if pad > 0 { data.append(Data(repeating: 0, count: pad)) }
  }

  // MARK: - Object decoding

  static func decodeObject(_ data: Data) throws -> XPCValue {
    let reader = Reader(data: data)
    let value = try decodeObject(reader: reader)
    guard reader.offset == data.count else {
      throw Error.malformed("trailing bytes after the XPC object")
    }
    return value
  }

  private static func decodeObject(reader: Reader) throws -> XPCValue {
    let rawType = try reader.readUInt32()
    guard let type = MessageType(rawValue: rawType) else {
      throw Error.unknownType(rawType)
    }
    switch type {
    case .null:
      return .null
    case .bool:
      let raw = try reader.readUInt32()
      guard raw == 0 || raw == 1 else {
        throw Error.malformed("Boolean value is not 0 or 1")
      }
      return .bool(raw == 1)
    case .int64:
      return .int64(Int64(bitPattern: try reader.readUInt64()))
    case .uint64:
      return .uint64(try reader.readUInt64())
    case .double:
      let raw = try reader.readUInt64()
      return .double(Double(bitPattern: raw.bigEndian))
    case .data:
      return .data(try readData(reader: reader, trailingNull: false))
    case .string:
      let bytes = try readData(reader: reader, trailingNull: true)
      guard let string = String(data: bytes, encoding: .utf8) else {
        throw Error.malformed("string is not valid UTF-8")
      }
      return .string(string)
    case .uuid:
      let bytes = try reader.read(count: 16)
      var loaded = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) as uuid_t
      withUnsafeMutableBytes(of: &loaded) { destination in
        bytes.copyBytes(to: destination)
      }
      return .uuid(UUID(uuid: loaded))
    case .array:
      let length = Int(try reader.readUInt32())
      let end = reader.offset + length
      guard end <= reader.data.count else { throw Error.truncated }
      let count = Int(try reader.readUInt32())
      var entries: [XPCValue] = []
      entries.reserveCapacity(count)
      for _ in 0..<count {
        entries.append(try decodeObject(reader: reader))
      }
      guard reader.offset == end else {
        throw Error.malformed("array length does not match its entries")
      }
      return .array(entries)
    case .dictionary:
      let length = Int(try reader.readUInt32())
      let end = reader.offset + length
      guard end <= reader.data.count else { throw Error.truncated }
      let count = Int(try reader.readUInt32())
      var entries: [String: XPCValue] = [:]
      entries.reserveCapacity(count)
      for _ in 0..<count {
        let keyStart = reader.offset
        var keyBytes = Data()
        var byte = try reader.readByte()
        while byte != 0 {
          keyBytes.append(byte)
          byte = try reader.readByte()
        }
        let keyLength = reader.offset - keyStart
        let pad = (4 - (keyLength % 4)) % 4
        try reader.skip(count: pad)
        guard let key = String(bytes: keyBytes, encoding: .utf8) else {
          throw Error.malformed("dictionary key is not valid UTF-8")
        }
        entries[key] = try decodeObject(reader: reader)
      }
      guard reader.offset == end else {
        throw Error.malformed("dictionary length does not match its entries")
      }
      return .dictionary(entries)
    default:
      throw Error.unsupportedValue(
        "message type 0x\(String(type.rawValue, radix: 16)) cannot be decoded")
    }
  }

  private static func readData(reader: Reader, trailingNull: Bool) throws -> Data {
    let length = Int(try reader.readUInt32())
    guard length >= 1, reader.offset + length <= reader.data.count else {
      throw Error.truncated
    }
    var payload = reader.data[reader.offset..<(reader.offset + length)]
    reader.offset += length
    if trailingNull {
      guard payload.last == 0 else {
        throw Error.malformed("string is missing its null terminator")
      }
      payload.removeLast()
    }
    let pad = (4 - (length % 4)) % 4
    try reader.skip(count: pad)
    return Data(payload)
  }

  // MARK: - Wrapper framing

  struct Wrapper: Equatable {
    var messageID: UInt64
    var flags: UInt32
    var value: XPCValue?
  }

  /// Encodes a request wrapper. The payload is the XpcPayload envelope
  /// (magic, protocol version, then the object); the stored length is the
  /// full payload byte count.
  static func encodeWrapper(value: XPCValue, messageID: UInt64, flags: UInt32) throws -> Data {
    let objectBytes = try encodeObject(value)
    let payloadLength = 8 + objectBytes.count
    let writer = Writer()
    writer.appendUInt32(wrapperMagic)
    writer.appendUInt32(flags)
    writer.appendUInt64(UInt64(payloadLength))
    writer.appendUInt64(messageID)
    writer.appendUInt32(payloadMagic)
    writer.appendUInt32(payloadProtocolVersion)
    writer.data.append(objectBytes)
    return writer.data
  }

  static func decodeWrapper(_ data: Data) throws -> Wrapper {
    let reader = Reader(data: data)
    let magic = try reader.readUInt32()
    guard magic == wrapperMagic else {
      throw Error.malformed("wrapper magic is invalid")
    }
    let flags = try reader.readUInt32()
    let payloadLength = Int(try reader.readUInt64())
    let messageID = try reader.readUInt64()
    let end = reader.offset + payloadLength
    guard end <= data.count else { throw Error.truncated }
    guard payloadLength > 0 else {
      return Wrapper(messageID: messageID, flags: flags, value: nil)
    }
    let payloadMagic = try reader.readUInt32()
    guard payloadMagic == Self.payloadMagic else {
      throw Error.malformed("wrapper payload magic is invalid")
    }
    let version = try reader.readUInt32()
    guard version == Self.payloadProtocolVersion else {
      throw Error.malformed("wrapper payload version is unsupported")
    }
    let value = try decodeObject(reader: reader)
    guard reader.offset == end else {
      throw Error.malformed("wrapper payload length does not match its object")
    }
    return Wrapper(messageID: messageID, flags: flags, value: value)
  }

  // MARK: - Flag constants

  enum Flags: UInt32 {
    case alwaysSet = 0x0000_0001
    case ping = 0x0000_0002
    case dataPresent = 0x0000_0100
    case wantingReply = 0x0001_0000
    case reply = 0x0002_0000
    case fileTXStreamRequest = 0x0010_0000
    case fileTXStreamResponse = 0x0020_0000
    case initHandshake = 0x0040_0000
  }

  // MARK: - Byte primitives

  final class Writer {
    var data = Data()

    func appendUInt32(_ value: UInt32) {
      var encoded = value.littleEndian
      withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    func appendUInt64(_ value: UInt64) {
      var encoded = value.littleEndian
      withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
  }

  final class Reader {
    let data: Data
    var offset = 0

    init(data: Data) {
      self.data = data
    }

    func readByte() throws -> UInt8 {
      guard offset < data.count else { throw Error.truncated }
      defer { offset += 1 }
      return data[offset]
    }

    func skip(count: Int) throws {
      guard count >= 0, offset + count <= data.count else { throw Error.truncated }
      offset += count
    }

    func read(count: Int) throws -> Data {
      guard count >= 0, offset + count <= data.count else {
        throw Error.truncated
      }
      defer { offset += count }
      return Data(data[offset..<(offset + count)])
    }

    func readUInt32() throws -> UInt32 {
      let bytes = try read(count: 4)
      return bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    func readUInt64() throws -> UInt64 {
      let bytes = try read(count: 8)
      return bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    }
  }
}
