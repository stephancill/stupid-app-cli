import Foundation

/// A minimal DNS-SD/mDNS client for discovering the device's
/// `_remotepairing._tcp.local.` advertisements over multicast UDP.
///
/// The parser and builder are pure functions so they can be covered by hermetic
/// tests with crafted packets; only `browse` touches the network.
public struct RemotepairingDiscovery: Sendable {
  public static let serviceType = "_remotepairing._tcp.local."
  public static let mDNSIPv4 = "224.0.0.251"
  public static let mDNSIPv6 = "ff02::fb"
  public static let mDNSPort: UInt16 = 5353

  public enum QType: UInt16 {
    case a = 1
    case ptr = 12
    case txt = 16
    case aaaa = 28
    case srv = 33
  }

  public struct Advertisement: Equatable, Sendable {
    public var instance: String
    public var host: String?
    public var port: Int?
    public var addresses: [Address]
    public var properties: [String: String]
  }

  public struct Address: Equatable, Sendable, Comparable {
    public var ip: String
    /// The interface name for IPv6 link-local addresses (`fe80::...`), which
    /// require a scope identifier to be reachable.
    public var interface: String?

    public var scopedIP: String {
      if let interface, ip.lowercased().hasPrefix("fe80:") {
        return "\(ip)%\(interface)"
      }
      return ip
    }

    public static func < (lhs: Address, rhs: Address) -> Bool {
      addressScore(lhs.scopedIP) < addressScore(rhs.scopedIP)
    }

    /// Mirrors the reference preference: link-local IPv4 first, then non-link-
    /// local, then link-local IPv6, then unspecified.
    static func addressScore(_ value: String) -> (Int, String) {
      if value.hasPrefix("192.168.") || value.hasPrefix("10.") || value.hasPrefix("172.") {
        return (0, value)
      }
      let lower = value.lowercased()
      if !lower.contains(":") {
        return (1, value)
      }
      if lower.hasPrefix("fe80:") || lower.hasPrefix("fe8") && lower.contains("%") {
        return (2, value)
      }
      return (3, value)
    }
  }

  // MARK: - Pure codec

  /// Encodes a dot-separated name into length-prefixed DNS labels with a
  /// trailing zero.
  static func encodeName(_ name: String) -> Data {
    let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
    var out = Data()
    for label in trimmed.split(separator: ".", omittingEmptySubsequences: true) {
      let bytes = Data(label.utf8)
      out.append(UInt8(bytes.count))
      out.append(contentsOf: bytes)
    }
    out.append(0)
    return out
  }

  /// Decodes a possibly-compressed DNS name starting at `offset`, returning the
  /// decoded name (with trailing dot) and the offset past the name in the
  /// current message.
  static func decodeName(_ data: Data, offset: Int) throws -> (name: String, next: Int) {
    var labels: [String] = []
    var cursor = offset
    var jumped = false
    var resolvedNext = offset
    var hops = 0
    while hops < 128 {
      hops += 1
      guard cursor < data.count else { throw DiscoveryError.malformed("truncated name") }
      let length = Int(data[cursor])
      if length == 0 {
        cursor += 1
        break
      }
      if length & 0xC0 == 0xC0 {
        guard cursor + 1 < data.count else {
          throw DiscoveryError.malformed("truncated name pointer")
        }
        let pointer = ((length & 0x3F) << 8) | Int(data[cursor + 1])
        guard pointer < data.count else {
          throw DiscoveryError.malformed("name pointer out of range")
        }
        if !jumped {
          resolvedNext = cursor + 2
          jumped = true
        }
        cursor = pointer
        continue
      }
      cursor += 1
      let end = cursor + length
      guard end <= data.count else { throw DiscoveryError.malformed("truncated label") }
      let labelData = data.subdata(in: cursor..<end)
      labels.append(String(decoding: labelData, as: UTF8.self))
      cursor = end
    }
    return (labels.joined(separator: ".") + ".", jumped ? resolvedNext : cursor)
  }

  /// Builds a single-question mDNS PTR query for a service type.
  static func buildPTRQuery(_ serviceType: String, unicast: Bool = false) -> Data {
    var out = Data()
    appendBigEndian(UInt16(0), to: &out)  // transaction id
    appendBigEndian(UInt16(0), to: &out)  // flags: standard query
    appendBigEndian(UInt16(1), to: &out)  // one question
    appendBigEndian(UInt16(0), to: &out)
    appendBigEndian(UInt16(0), to: &out)
    appendBigEndian(UInt16(0), to: &out)
    out.append(encodeName(serviceType))
    appendBigEndian(QType.ptr.rawValue, to: &out)
    appendBigEndian(UInt16(0x0001 | (unicast ? 0x8000 : 0)), to: &out)
    return out
  }

  /// Parses the answers/additional records out of one mDNS message.
  static func parseRecords(_ data: Data) throws -> [Record] {
    guard data.count >= 12 else { throw DiscoveryError.malformed("message too short") }
    let questionCount = bigEndianUInt16(data, at: 4)
    let answerCount = bigEndianUInt16(data, at: 6)
    let authorityCount = bigEndianUInt16(data, at: 8)
    let additionalCount = bigEndianUInt16(data, at: 10)
    var cursor = 12
    var records: [Record] = []
    for _ in 0..<Int(questionCount) {
      let name = try decodeName(data, offset: cursor)
      cursor = name.next + 4
      guard cursor <= data.count else { throw DiscoveryError.malformed("question overflow") }
    }
    let total = Int(answerCount) + Int(authorityCount) + Int(additionalCount)
    for _ in 0..<total {
      let name = try decodeName(data, offset: cursor)
      cursor = name.next
      guard cursor + 10 <= data.count else {
        throw DiscoveryError.malformed("record header overflow")
      }
      let type = bigEndianUInt16(data, at: cursor)
      let rrClass = bigEndianUInt16(data, at: cursor + 2)
      let ttl = bigEndianUInt32(data, at: cursor + 4)
      let rdLength = Int(bigEndianUInt16(data, at: cursor + 8))
      cursor += 10
      guard cursor + rdLength <= data.count else {
        throw DiscoveryError.malformed("record data overflow")
      }
      let rdata = data.subdata(in: cursor..<(cursor + rdLength))
      cursor += rdLength
      records.append(
        try parseRecord(
          name: name.name, type: type, rrClass: rrClass, ttl: ttl, rdata: rdata, message: data,
          cursor: cursor))
    }
    return records
  }

  struct Record: Sendable {
    var name: String
    var type: UInt16
    var ttl: UInt32
    var ptrTarget: String?
    var srv: (priority: UInt16, weight: UInt16, port: UInt16, target: String)?
    var txt: [String: String]?
    var address: String?
  }

  private static func parseRecord(
    name: String, type: UInt16, rrClass: UInt16, ttl: UInt32, rdata: Data,
    message: Data, cursor: Int
  ) throws -> Record {
    var record = Record(
      name: name, type: type, ttl: ttl, ptrTarget: nil, srv: nil, txt: nil, address: nil)
    switch type {
    case QType.ptr.rawValue:
      let target = try decodeName(message, offset: cursor - rdata.count)
      record.ptrTarget = target.name
    case QType.srv.rawValue:
      if rdata.count >= 6 {
        let priority = bigEndianUInt16(rdata, at: 0)
        let weight = bigEndianUInt16(rdata, at: 2)
        let port = bigEndianUInt16(rdata, at: 4)
        let target = try decodeName(message, offset: cursor - rdata.count + 6)
        record.srv = (priority, weight, port, target.name)
      }
    case QType.txt.rawValue:
      record.txt = parseTXT(rdata)
    case QType.a.rawValue:
      if rdata.count == 4 {
        record.address = "\(rdata[0]).\(rdata[1]).\(rdata[2]).\(rdata[3])"
      }
    case QType.aaaa.rawValue:
      if rdata.count == 16 {
        record.address = formatIPv6(rdata)
      }
    default:
      break
    }
    _ = rrClass
    return record
  }

  static func parseTXT(_ data: Data) -> [String: String] {
    var properties: [String: String] = [:]
    var cursor = 0
    while cursor < data.count {
      let length = Int(data[cursor])
      cursor += 1
      let end = cursor + length
      guard end <= data.count else { break }
      let segment = data.subdata(in: cursor..<end)
      cursor = end
      guard let separator = segment.firstIndex(of: 0x3D) else {
        if let key = String(data: segment, encoding: .utf8) {
          properties[key] = ""
        }
        continue
      }
      let keyData = segment[..<separator]
      let valueData = segment[segment.index(after: separator)...]
      if let key = String(data: keyData, encoding: .utf8) {
        properties[key] = String(data: valueData, encoding: .utf8) ?? ""
      }
    }
    return properties
  }

  static func formatIPv6(_ bytes: Data) -> String {
    var groups: [Int] = []
    for index in stride(from: 0, to: 16, by: 2) {
      groups.append((Int(bytes[index]) << 8) | Int(bytes[index + 1]))
    }
    // Compress the longest run of zero groups (RFC 5952), preferring the
    // earliest run on a tie, but never compressing a single zero.
    var bestStart = -1
    var bestLength = 0
    var currentStart = -1
    var currentLength = 0
    for (index, value) in groups.enumerated() {
      if value == 0 {
        if currentStart < 0 { currentStart = index }
        currentLength += 1
        if currentLength > bestLength {
          bestStart = currentStart
          bestLength = currentLength
        }
      } else {
        currentStart = -1
        currentLength = 0
      }
    }
    if bestLength < 2 {
      return groups.map { String($0, radix: 16) }.joined(separator: ":")
    }
    var pieces: [String] = []
    var index = 0
    while index < groups.count {
      if index == bestStart {
        pieces.append("")
        index += bestLength
        continue
      }
      pieces.append(String(groups[index], radix: 16))
      index += 1
    }
    return pieces.joined(separator: ":")
  }

  // MARK: - Network browse

  /// Discovers remote-pairing advertisements on the local network for up to
  /// `timeout` seconds, returning parsed service instances.
  public func browse(timeout: Double) throws -> [Advertisement] {
    guard timeout > 0 else {
      throw DiscoveryError.invalidInput("timeout must be positive")
    }
    let socket4: Int32
    let socket6: Int32?
    do {
      socket4 = try Self.openMulticastSocket(ipv6: false)
      socket6 = try? Self.openMulticastSocket(ipv6: true)
    } catch {
      if let socket6 = try? Self.openMulticastSocket(ipv6: true) {
        Self.closeSocket(socket6)
      }
      throw error
    }
    defer {
      Self.closeSocket(socket4)
      if let socket6 { Self.closeSocket(socket6) }
    }

    try sendPTRQuery(socket4, ipv6: false)
    if let socket6 { try? sendPTRQuery(socket6, ipv6: true) }

    var records: [Record] = []
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { break }
      for socket in [socket4, socket6].compactMap({ $0 }) {
        guard Date() < deadline else { break }
        guard let message = try? Self.receive(descriptor: socket, timeout: min(0.2, remaining)),
          let parsed = try? Self.parseRecords(message)
        else { continue }
        records.append(contentsOf: parsed)
      }
    }
    return Self.assemble(records)
  }

  /// Reads one datagram with an `SO_RCVTIMEO` so a silent multicast group does
  /// not block the browse loop.
  private static func receive(descriptor: Int32, timeout: Double) throws -> Data {
    var receiveTimeout = timeval(
      tv_sec: Int(timeout),
      tv_usec: suseconds_t((timeout - Double(Int(timeout))) * 1_000_000))
    setsockopt(
      descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
      socklen_t(MemoryLayout<timeval>.size))
    var buffer = [UInt8](repeating: 0, count: 65_536)
    let count = buffer.withUnsafeMutableBytes {
      recv(descriptor, $0.baseAddress!, $0.count, 0)
    }
    guard count > 0 else { throw DiscoveryError.transport("no datagram") }
    return Data(buffer.prefix(count))
  }

  static func assemble(_ records: [Record]) -> [Advertisement] {
    var ptrTargets: Set<String> = []
    var srvMap: [String: [(target: String, port: Int)]] = [:]
    var txtMap: [String: [String: String]] = [:]
    var hostAddresses: [String: [Address]] = [:]

    for record in records {
      switch record.type {
      case QType.ptr.rawValue:
        if record.name == serviceType, let target = record.ptrTarget {
          ptrTargets.insert(target)
        }
      case QType.srv.rawValue:
        if let srv = record.srv {
          let target = srv.target.hasSuffix(".") ? String(srv.target.dropLast()) : srv.target
          srvMap[record.name, default: []].append((target, Int(srv.port)))
        }
      case QType.txt.rawValue:
        if let txt = record.txt {
          txtMap[record.name] = txt
        }
      case QType.a.rawValue, QType.aaaa.rawValue:
        if let address = record.address {
          let hostKey = record.name.hasSuffix(".") ? String(record.name.dropLast()) : record.name
          let existing = hostAddresses[hostKey] ?? []
          if !existing.contains(where: { $0.ip == address }) {
            hostAddresses[hostKey, default: []].append(Address(ip: address, interface: nil))
          }
        }
      default:
        break
      }
    }

    var results: [Advertisement] = []
    for instance in ptrTargets.sorted() {
      let properties = txtMap[instance] ?? [:]
      for srv in srvMap[instance] ?? [] {
        let addresses = hostAddresses[srv.target] ?? []
        let sorted = addresses.sorted()
        results.append(
          Advertisement(
            instance: instance, host: srv.target, port: srv.port, addresses: sorted,
            properties: properties))
      }
    }
    return results
  }

  private func sendPTRQuery(_ socket: Int32, ipv6: Bool) throws {
    let query = Self.buildPTRQuery(Self.serviceType)
    let sent: Int
    if ipv6 {
      var address = sockaddr_in6()
      address.sin6_family = sa_family_t(AF_INET6)
      address.sin6_port = Self.mDNSPort.bigEndian
      inet_pton(AF_INET6, Self.mDNSIPv6, &address.sin6_addr)
      sent = query.withUnsafeBytes { bytes in
        withUnsafeBytes(of: &address) { sockaddrBytes in
          sendto(
            socket, bytes.baseAddress!, bytes.count, 0,
            sockaddrBytes.bindMemory(to: sockaddr.self).baseAddress,
            socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
      }
    } else {
      var address = sockaddr_in()
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = Self.mDNSPort.bigEndian
      inet_pton(AF_INET, Self.mDNSIPv4, &address.sin_addr)
      sent = query.withUnsafeBytes { bytes in
        withUnsafeBytes(of: &address) { sockaddrBytes in
          sendto(
            socket, bytes.baseAddress!, bytes.count, 0,
            sockaddrBytes.bindMemory(to: sockaddr.self).baseAddress,
            socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
    guard sent == query.count else {
      throw DiscoveryError.transport("could not send the mDNS query")
    }
  }

  private static func openMulticastSocket(ipv6: Bool) throws -> Int32 {
    let family = ipv6 ? AF_INET6 : AF_INET
    #if os(Linux)
      let socketType = Int32(SOCK_DGRAM.rawValue)
    #else
      let socketType = SOCK_DGRAM
    #endif
    let socket = socket(family, socketType, 0)
    guard socket >= 0 else { throw DiscoveryError.transport("could not open a UDP socket") }

    var reuse: Int32 = 1
    setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    #if !os(Linux)
      setsockopt(socket, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
    #endif

    if ipv6 {
      var address = sockaddr_in6()
      address.sin6_family = sa_family_t(AF_INET6)
      address.sin6_port = mDNSPort.bigEndian
      address.sin6_addr = in6addr_any
      var bound = false
      withUnsafeBytes(of: &address) { bytes in
        bound =
          bind(
            socket, bytes.bindMemory(to: sockaddr.self).baseAddress,
            socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
      }
      if !bound {
        closeSocket(socket)
        throw DiscoveryError.transport("could not bind the IPv6 mDNS socket")
      }
      var group = in6_addr()
      let groupText = Self.mDNSIPv6
      inet_pton(AF_INET6, groupText, &group)
      var request = ipv6_mreq()
      request.ipv6mr_multiaddr = group
      request.ipv6mr_interface = 0
      let result = withUnsafeBytes(of: &request) { bytes in
        setsockopt(
          socket, Int32(IPPROTO_IPV6), IPV6_JOIN_GROUP,
          bytes.bindMemory(to: cmsghdr.self).baseAddress,
          socklen_t(MemoryLayout<ipv6_mreq>.size))
      }
      if result != 0 {
        closeSocket(socket)
        throw DiscoveryError.transport("could not join the IPv6 multicast group")
      }
    } else {
      var address = sockaddr_in()
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = mDNSPort.bigEndian
      address.sin_addr.s_addr = INADDR_ANY.bigEndian
      var bound = false
      withUnsafeBytes(of: &address) { bytes in
        bound =
          bind(
            socket, bytes.bindMemory(to: sockaddr.self).baseAddress,
            socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
      if !bound {
        closeSocket(socket)
        throw DiscoveryError.transport("could not bind the IPv4 mDNS socket")
      }
      var group = in_addr()
      inet_pton(AF_INET, Self.mDNSIPv4, &group)
      var request = ip_mreq()
      request.imr_multiaddr = group
      request.imr_interface.s_addr = INADDR_ANY.bigEndian
      let result = withUnsafeBytes(of: &request) { bytes in
        setsockopt(
          socket, Int32(IPPROTO_IP), IP_ADD_MEMBERSHIP,
          bytes.bindMemory(to: cmsghdr.self).baseAddress,
          socklen_t(MemoryLayout<ip_mreq>.size))
      }
      if result != 0 {
        closeSocket(socket)
        throw DiscoveryError.transport("could not join the IPv4 multicast group")
      }
    }
    return socket
  }

  private static func closeSocket(_ descriptor: Int32) {
    close(descriptor)
  }

  // MARK: - Little helpers

  static func appendBigEndian(_ value: UInt16, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
  }

  static func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
  }

  static func bigEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
    data.withUnsafeBytes {
      UInt16(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }
  }

  static func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    data.withUnsafeBytes {
      UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
  }
}

enum DiscoveryError: Swift.Error, Equatable, Sendable, CustomStringConvertible {
  case invalidInput(String)
  case malformed(String)
  case transport(String)

  var description: String {
    switch self {
    case .invalidInput(let detail):
      return "Remote-pairing discovery input is invalid: \(detail)."
    case .malformed(let detail):
      return "The mDNS message is malformed: \(detail)."
    case .transport(let detail):
      return "Remote-pairing discovery failed: \(detail)."
    }
  }
}
