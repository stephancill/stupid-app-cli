import Foundation

/// Minimal HTTP/2 client framing used by Apple's RemoteXPC services.
enum HTTP2Frame {
  enum Kind: UInt8 {
    case data = 0x0
    case headers = 0x1
    case priority = 0x2
    case rstStream = 0x3
    case settings = 0x4
    case pushPromise = 0x5
    case ping = 0x6
    case goaway = 0x7
    case windowUpdate = 0x8
    case continuation = 0x9
  }

  struct Flags: OptionSet, Equatable {
    let rawValue: UInt8

    static let endStream = Flags(rawValue: 0x1)
    static let ack = Flags(rawValue: 0x1)
    static let endHeaders = Flags(rawValue: 0x4)
    static let padded = Flags(rawValue: 0x8)
  }

  static let magic = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)

  static func encode(kind: Kind, flags: UInt8 = 0, streamID: UInt32 = 0, payload: Data = Data())
    -> Data
  {
    var out = Data()
    out.append(UInt8((payload.count >> 16) & 0xff))
    out.append(UInt8((payload.count >> 8) & 0xff))
    out.append(UInt8(payload.count & 0xff))
    out.append(kind.rawValue)
    out.append(flags)
    var id = (streamID & 0x7fff_ffff).bigEndian
    withUnsafeBytes(of: &id) { out.append(contentsOf: $0) }
    out.append(payload)
    return out
  }

  static func settingsFrame(pairs: [(id: UInt16, value: UInt32)]) -> Data {
    var payload = Data()
    for pair in pairs {
      payload.append(UInt8(pair.id >> 8))
      payload.append(UInt8(pair.id & 0xff))
      var value = pair.value.bigEndian
      withUnsafeBytes(of: &value) { payload.append(contentsOf: $0) }
    }
    return encode(kind: .settings, streamID: 0, payload: payload)
  }

  static func settingsAck() -> Data {
    encode(kind: .settings, flags: Flags.ack.rawValue, streamID: 0)
  }

  static func windowUpdate(streamID: UInt32, increment: UInt32) -> Data {
    var payload = Data()
    var value = (increment & 0x7fff_ffff).bigEndian
    withUnsafeBytes(of: &value) { payload.append(contentsOf: $0) }
    return encode(kind: .windowUpdate, streamID: streamID, payload: payload)
  }

  static func headersFrame(streamID: UInt32, endStream: Bool = false) -> Data {
    let flags = Flags.endHeaders.rawValue | (endStream ? Flags.endStream.rawValue : 0)
    return encode(kind: .headers, flags: flags, streamID: streamID)
  }

  static func dataFrame(streamID: UInt32, payload: Data, endStream: Bool = false) -> Data {
    let flags: UInt8 = endStream ? Flags.endStream.rawValue : 0
    return encode(kind: .data, flags: flags, streamID: streamID, payload: payload)
  }

  static func decodeHeader(_ data: Data) throws -> (
    length: Int, kind: Kind, flags: UInt8, streamID: UInt32
  ) {
    guard data.count == 9 else {
      throw Error.malformed("frame header is not 9 bytes")
    }
    let length = (Int(data[0]) << 16) | (Int(data[1]) << 8) | Int(data[2])
    guard let kind = Kind(rawValue: data[3]) else {
      throw Error.malformed("unsupported HTTP/2 frame type \(data[3])")
    }
    let flags = data[4]
    let streamB = data.withUnsafeBytes {
      UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 5, as: UInt32.self))
    }
    return (length, kind, flags, streamB & 0x7fff_ffff)
  }

  enum Error: Swift.Error, Equatable, CustomStringConvertible {
    case malformed(String)

    var description: String {
      switch self {
      case .malformed(let detail):
        return "The RemoteXPC HTTP/2 stream is malformed: \(detail)."
      }
    }
  }
}
