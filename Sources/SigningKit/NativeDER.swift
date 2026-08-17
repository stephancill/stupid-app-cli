import Foundation

enum NativeDER {
  struct Node {
    let tag: UInt8
    let encoded: Data
    let content: Data
  }

  enum Error: Swift.Error {
    case malformed(String)
  }

  static func node(_ tag: UInt8, _ content: Data) -> Data {
    Data([tag]) + length(content.count) + content
  }

  static func sequence(_ values: [Data]) -> Data { node(0x30, values.reduce(Data(), +)) }
  static func set(_ values: [Data]) -> Data {
    node(0x31, values.sorted { $0.lexicographicallyPrecedes($1) }.reduce(Data(), +))
  }
  static func integer(_ bytes: Data) -> Data {
    node(0x02, bytes.first.map { $0 & 0x80 == 0 ? bytes : Data([0]) + bytes } ?? Data([0]))
  }
  static func integer(_ value: Int64) -> Data {
    var bytes = withUnsafeBytes(of: value.bigEndian) { Array($0) }
    while bytes.count > 1 {
      if bytes[0] == 0, bytes[1] & 0x80 == 0 {
        bytes.removeFirst()
      } else if bytes[0] == 0xFF, bytes[1] & 0x80 != 0 {
        bytes.removeFirst()
      } else {
        break
      }
    }
    return node(0x02, Data(bytes))
  }
  static func boolean(_ value: Bool) -> Data { node(0x01, Data([value ? 0xFF : 0])) }
  static func utf8(_ value: String) -> Data { node(0x0C, Data(value.utf8)) }
  static func octetString(_ value: Data) -> Data { node(0x04, value) }
  static func null() -> Data { node(0x05, Data()) }

  static func oid(_ value: String) throws -> Data {
    let components = try value.split(separator: ".").map {
      guard let component = UInt64($0) else { throw Error.malformed("invalid object identifier") }
      return component
    }
    guard components.count >= 2, components[0] <= 2, components[1] < 40 || components[0] == 2 else {
      throw Error.malformed("invalid object identifier")
    }
    var content = base128(components[0] * 40 + components[1])
    for component in components.dropFirst(2) { content += base128(component) }
    return node(0x06, content)
  }

  static func parseOne(_ data: Data, offset: inout Int) throws -> Node {
    guard offset < data.count else { throw Error.malformed("DER value is truncated") }
    let start = offset
    let tag = data[offset]
    offset += 1
    guard offset < data.count else { throw Error.malformed("DER length is truncated") }
    let first = data[offset]
    offset += 1
    let count: Int
    if first & 0x80 == 0 {
      count = Int(first)
    } else {
      let byteCount = Int(first & 0x7F)
      guard byteCount > 0, byteCount <= MemoryLayout<Int>.size, offset <= data.count - byteCount
      else {
        throw Error.malformed("DER length is invalid")
      }
      var value = 0
      for byte in data[offset..<(offset + byteCount)] {
        let (shifted, overflow) = value.multipliedReportingOverflow(by: 256)
        let (next, addOverflow) = shifted.addingReportingOverflow(Int(byte))
        guard !overflow, !addOverflow else { throw Error.malformed("DER length overflows") }
        value = next
      }
      guard value >= 128 else { throw Error.malformed("DER length is not canonical") }
      offset += byteCount
      count = value
    }
    guard count >= 0, offset <= data.count - count else {
      throw Error.malformed("DER content is truncated")
    }
    let content = data.subdata(in: offset..<(offset + count))
    offset += count
    return Node(tag: tag, encoded: data.subdata(in: start..<offset), content: content)
  }

  static func children(_ node: Node) throws -> [Node] {
    var offset = 0
    var result = [Node]()
    while offset < node.content.count { result.append(try parseOne(node.content, offset: &offset)) }
    return result
  }

  static func pemDER(_ pem: String, label: String = "CERTIFICATE") throws -> Data {
    let begin = "-----BEGIN \(label)-----"
    let end = "-----END \(label)-----"
    guard let beginRange = pem.range(of: begin), let endRange = pem.range(of: end),
      beginRange.upperBound <= endRange.lowerBound
    else {
      throw Error.malformed("missing PEM \(label)")
    }
    let body = pem[beginRange.upperBound..<endRange.lowerBound].filter { !$0.isWhitespace }
    guard let der = Data(base64Encoded: String(body)) else {
      throw Error.malformed("invalid PEM base64")
    }
    return der
  }

  private static func length(_ count: Int) -> Data {
    if count < 128 { return Data([UInt8(count)]) }
    var value = count
    var bytes = [UInt8]()
    while value > 0 {
      bytes.insert(UInt8(value & 0xFF), at: 0)
      value >>= 8
    }
    return Data([0x80 | UInt8(bytes.count)] + bytes)
  }

  private static func base128(_ value: UInt64) -> Data {
    var value = value
    var bytes = [UInt8(value & 0x7F)]
    value >>= 7
    while value > 0 {
      bytes.insert(UInt8(value & 0x7F) | 0x80, at: 0)
      value >>= 7
    }
    return Data(bytes)
  }
}
