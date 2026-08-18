import Foundation

/// A minimal OPACK encoder for the CoreDevice pairing `device_info` value.
/// OPACK is Apple's compact binary serialization used during remote pairing.
/// This covers the value types the pairing flow emits: bytes, strings, small
/// integers, booleans, arrays, and ordered dictionaries.
indirect enum OPackValue {
  case bool(Bool)
  case int(Int64)
  case string(String)
  case data(Data)
  case array([OPackValue])
  case dictionary([OPackEntry])
}

struct OPackEntry {
  let key: OPackValue
  let value: OPackValue
}

enum OPack {
  static func encode(_ value: OPackValue) -> Data {
    var out = Data()
    encode(value, into: &out)
    return out
  }

  static func encodeDictionary(_ pairs: [OPackEntry]) -> Data {
    encode(.dictionary(pairs))
  }

  private static func encode(_ value: OPackValue, into out: inout Data) {
    switch value {
    case .bool(true):
      out.append(0x01)
    case .bool(false):
      out.append(0x02)
    case .int(let number):
      encodeInt(number, into: &out)
    case .string(let string):
      encodeString(string, into: &out)
    case .data(let bytes):
      encodeBytes(bytes, into: &out)
    case .array(let elements):
      if elements.count < 15 {
        out.append(UInt8(0xD0 + elements.count))
        for element in elements {
          encode(element, into: &out)
        }
      } else {
        out.append(0xDF)
        for element in elements {
          encode(element, into: &out)
        }
        out.append(0x03)
      }
    case .dictionary(let pairs):
      if pairs.count < 15 {
        out.append(UInt8(0xE0 + pairs.count))
        for pair in pairs {
          encode(pair.key, into: &out)
          encode(pair.value, into: &out)
        }
      } else {
        out.append(0xEF)
        for pair in pairs {
          encode(pair.key, into: &out)
          encode(pair.value, into: &out)
        }
        out.append(0x03)
      }
    }
  }

  private static func encodeInt(_ number: Int64, into out: inout Data) {
    if number >= 0, number <= 0x27 {
      out.append(UInt8(number + 8))
      return
    }
    // Only non-negative integers are emitted by this flow.
    _ = number
    out.append(0x33)
    var value = UInt64(bitPattern: number).bigEndian
    withUnsafeBytes(of: &value) { out.append(contentsOf: $0) }
  }

  private static func encodeString(_ string: String, into out: inout Data) {
    let bytes = Data(string.utf8)
    let length = bytes.count
    if length <= 0x20 {
      out.append(UInt8(0x40 + length))
      out.append(bytes)
    } else if length <= 0xFF {
      out.append(0x61)
      out.append(UInt8(length))
      out.append(bytes)
    } else if length <= 0xFFFF {
      out.append(0x62)
      var encoded = UInt16(length).bigEndian
      withUnsafeBytes(of: &encoded) { out.append(contentsOf: $0) }
      out.append(bytes)
    } else {
      out.append(0x63)
      var encoded = UInt32(length).bigEndian
      withUnsafeBytes(of: &encoded) { out.append(contentsOf: $0) }
      out.append(bytes)
    }
  }

  private static func encodeBytes(_ bytes: Data, into out: inout Data) {
    let length = bytes.count
    if length <= 0x20 {
      out.append(UInt8(0x70 + length))
      out.append(bytes)
    } else if length <= 0xFF {
      out.append(0x91)
      out.append(UInt8(length))
      out.append(bytes)
    } else if length <= 0xFFFF {
      out.append(0x92)
      var encoded = UInt16(length).bigEndian
      withUnsafeBytes(of: &encoded) { out.append(contentsOf: $0) }
      out.append(bytes)
    } else if length < 0x1_0000_0000 {
      out.append(0x93)
      var encoded = UInt32(length).bigEndian
      withUnsafeBytes(of: &encoded) { out.append(contentsOf: $0) }
      out.append(bytes)
    } else {
      out.append(0x94)
      var encoded = UInt64(length).bigEndian
      withUnsafeBytes(of: &encoded) { out.append(contentsOf: $0) }
      out.append(bytes)
    }
  }
}
