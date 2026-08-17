import CLockdownTLS
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct USBMuxDevice: Equatable, Sendable {
  public enum ConnectionType: String, Sendable {
    case usb = "USB"
    case network = "Network"
  }

  public var deviceID: UInt32
  public var serialNumber: String
  public var connectionType: ConnectionType

  public init(deviceID: UInt32, serialNumber: String, connectionType: ConnectionType) {
    self.deviceID = deviceID
    self.serialNumber = serialNumber
    self.connectionType = connectionType
  }
}

public struct LockdownPairRecord: Equatable, Sendable {
  public var hostID: String
  public var systemBUID: String
  public var hostCertificate: Data
  public var hostPrivateKey: Data
  public var escrowBag: Data?

  public init(data: Data) throws {
    guard
      let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let hostID = value["HostID"] as? String,
      !hostID.isEmpty,
      let systemBUID = value["SystemBUID"] as? String,
      !systemBUID.isEmpty,
      let hostCertificate = value["HostCertificate"] as? Data,
      !hostCertificate.isEmpty,
      let hostPrivateKey = value["HostPrivateKey"] as? Data,
      !hostPrivateKey.isEmpty
    else {
      throw USBMuxClient.Error.invalidInput("pair record is missing required session credentials")
    }
    self.hostID = hostID
    self.systemBUID = systemBUID
    self.hostCertificate = hostCertificate
    self.hostPrivateKey = hostPrivateKey
    self.escrowBag = value["EscrowBag"] as? Data
  }
}

public enum LockdownPairingResult: Equatable, Sendable {
  case reusedExistingRecord
  case createdRecord
}

public struct LockdownService: Equatable, Sendable {
  public var port: UInt16
  public var enablesTLS: Bool

  public init(port: UInt16, enablesTLS: Bool) {
    self.port = port
    self.enablesTLS = enablesTLS
  }
}

/// Native plist-protocol client for an existing usbmuxd Unix or TCP socket.
public struct USBMuxClient: USBDeviceDiscovering, Sendable {
  static let maximumPacketBytes = 16 * 1_024 * 1_024
  static let plistVersion: UInt32 = 1
  static let plistMessage: UInt32 = 8

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidAddress
    case invalidInput(String)
    case connectionFailed(Int32)
    case timedOut
    case connectionClosed
    case malformedPacket(String)
    case invalidResponse(String)
    case muxResult(UInt32)

    public var description: String {
      switch self {
      case .invalidAddress:
        return "The usbmuxd address is invalid. Use a Unix socket path or numeric HOST:PORT."
      case .invalidInput(let detail):
        return "The usbmux request is invalid: \(detail)."
      case .connectionFailed(let code):
        return "Could not connect to usbmuxd (public error code \(code))."
      case .timedOut:
        return "The usbmuxd operation timed out. Confirm the daemon and device are available."
      case .connectionClosed:
        return "usbmuxd closed the connection before completing the operation."
      case .malformedPacket(let detail):
        return "usbmuxd returned a malformed packet: \(detail)."
      case .invalidResponse(let detail):
        return "usbmuxd returned an unexpected response: \(detail)."
      case .muxResult(let code):
        return "usbmuxd rejected the operation with result code \(code)."
      }
    }
  }

  public var address: String
  public var timeoutSeconds: Double

  public init(address: String? = nil, timeoutSeconds: Double = 15) {
    self.address = address ?? "/var/run/usbmuxd"
    self.timeoutSeconds = timeoutSeconds
  }

  public func devices() throws -> [USBMuxDevice] {
    let response = try request(["MessageType": "ListDevices"])
    guard let list = response["DeviceList"] as? [[String: Any]] else {
      throw Error.invalidResponse("ListDevices omitted DeviceList")
    }
    return try list.compactMap { item in
      guard (item["MessageType"] as? String) != "Detached" else { return nil }
      guard
        let deviceID = Self.uint32(item["DeviceID"]),
        let properties = item["Properties"] as? [String: Any],
        let serial = properties["SerialNumber"] as? String,
        !serial.isEmpty,
        let typeValue = properties["ConnectionType"] as? String,
        let connectionType = USBMuxDevice.ConnectionType(rawValue: typeValue)
      else {
        throw Error.invalidResponse("ListDevices contained an invalid device")
      }
      return USBMuxDevice(
        deviceID: deviceID,
        serialNumber: serial,
        connectionType: connectionType
      )
    }
  }

  public func usbDeviceUDIDs() throws -> [String] {
    try devices().filter { $0.connectionType == .usb }.map(\.serialNumber)
  }

  public func readBUID() throws -> String {
    let response = try request(["MessageType": "ReadBUID"])
    guard let buid = response["BUID"] as? String, !buid.isEmpty else {
      throw Error.invalidResponse("ReadBUID omitted BUID")
    }
    return buid
  }

  public func readPairRecord(identifier: String) throws -> Data? {
    guard !identifier.isEmpty else { throw Error.invalidInput("pair record identifier is empty") }
    let response = try request([
      "MessageType": "ReadPairRecord",
      "PairRecordID": identifier,
    ])
    return response["PairRecordData"] as? Data
  }

  public func savePairRecord(identifier: String, deviceID: UInt32, data: Data) throws {
    guard !identifier.isEmpty else { throw Error.invalidInput("pair record identifier is empty") }
    guard !data.isEmpty else { throw Error.invalidInput("pair record data is empty") }
    let response = try request([
      "MessageType": "SavePairRecord",
      "PairRecordID": identifier,
      "PairRecordData": data,
      "DeviceID": deviceID,
    ])
    try Self.validateResult(response)
  }

  public func connectLockdown(deviceID: UInt32) throws -> LockdownClient {
    let connection = try connect(deviceID: deviceID, port: 62_078)
    return LockdownClient(connection: connection)
  }

  public func connectService(
    deviceID: UInt32,
    service: LockdownService,
    pairRecord: LockdownPairRecord
  ) throws -> LockdownServiceConnection {
    let connection = try connect(deviceID: deviceID, port: service.port)
    if service.enablesTLS {
      try connection.enableTLS(using: pairRecord)
    }
    return LockdownServiceConnection(connection: connection)
  }

  private func connect(deviceID: UInt32, port: UInt16) throws -> SocketConnection {
    let connection = try SocketConnection(address: address, timeoutSeconds: timeoutSeconds)
    let request: [String: Any] = [
      "MessageType": "Connect",
      "DeviceID": deviceID,
      // usbmuxd expects the service port represented in network byte order.
      "PortNumber": UInt16(bigEndian: port),
    ]
    let response = try exchange(request, over: connection)
    try Self.validateResult(response)
    return connection
  }

  func request(_ body: [String: Any]) throws -> [String: Any] {
    let connection = try SocketConnection(address: address, timeoutSeconds: timeoutSeconds)
    return try exchange(body, over: connection)
  }

  private func exchange(
    _ body: [String: Any],
    over connection: SocketConnection
  ) throws -> [String: Any] {
    let tag: UInt32 = 1
    try connection.write(Self.encodePacket(body: Self.withClientMetadata(body), tag: tag))
    let header = try connection.read(count: 16)
    let decodedHeader = try Self.decodeHeader(header)
    guard decodedHeader.tag == tag else {
      throw Error.malformedPacket("response tag does not match request")
    }
    guard
      decodedHeader.version == Self.plistVersion,
      decodedHeader.message == Self.plistMessage
    else {
      throw Error.malformedPacket("response is not a plist protocol packet")
    }
    let payload = try connection.read(count: decodedHeader.length - 16)
    guard
      let object = try PropertyListSerialization.propertyList(from: payload, format: nil)
        as? [String: Any]
    else {
      throw Error.malformedPacket("plist payload is not a dictionary")
    }
    return object
  }

  static func encodePacket(body: [String: Any], tag: UInt32) throws -> Data {
    let payload = try PropertyListSerialization.data(
      fromPropertyList: body,
      format: .xml,
      options: 0
    )
    let length = 16 + payload.count
    guard length <= maximumPacketBytes else {
      throw Error.invalidInput("packet exceeds 16 MiB")
    }
    var packet = Data()
    appendLittleEndian(UInt32(length), to: &packet)
    appendLittleEndian(plistVersion, to: &packet)
    appendLittleEndian(plistMessage, to: &packet)
    appendLittleEndian(tag, to: &packet)
    packet.append(payload)
    return packet
  }

  static func decodeHeader(_ data: Data) throws -> (
    length: Int, version: UInt32, message: UInt32, tag: UInt32
  ) {
    guard data.count == 16 else { throw Error.malformedPacket("header is truncated") }
    let length = Int(littleEndianUInt32(data, at: 0))
    guard (16...maximumPacketBytes).contains(length) else {
      throw Error.malformedPacket("packet length is outside 16 bytes...16 MiB")
    }
    return (
      length,
      littleEndianUInt32(data, at: 4),
      littleEndianUInt32(data, at: 8),
      littleEndianUInt32(data, at: 12)
    )
  }

  static func withClientMetadata(_ body: [String: Any]) -> [String: Any] {
    var request: [String: Any] = [
      "ClientVersionString": "stupid-app",
      "ProgName": "stupid-app",
      "kLibUSBMuxVersion": 3,
    ]
    request.merge(body) { _, supplied in supplied }
    return request
  }

  static func validateResult(_ response: [String: Any]) throws {
    guard response["MessageType"] as? String == "Result" else {
      throw Error.invalidResponse("operation did not return a Result message")
    }
    guard let number = uint32(response["Number"]) else {
      throw Error.invalidResponse("Result omitted Number")
    }
    guard number == 0 else { throw Error.muxResult(number) }
  }

  private static func uint32(_ value: Any?) -> UInt32? {
    guard let number = value as? NSNumber else { return nil }
    let unsigned = number.uint64Value
    guard unsigned <= UInt32.max else { return nil }
    return UInt32(unsigned)
  }

  private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
    var encoded = value.littleEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
  }

  private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
    data.withUnsafeBytes { bytes in
      UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
  }
}

public final class LockdownClient: @unchecked Sendable {
  public static let serviceType = "com.apple.mobile.lockdown"
  private let connection: SocketConnection
  private var sessionID: String?

  fileprivate init(connection: SocketConnection) {
    self.connection = connection
  }

  public func queryType(label: String = "stupid-app") throws -> String {
    let response = try request(name: "QueryType", label: label)
    guard let type = response["Type"] as? String, type == Self.serviceType else {
      throw USBMuxClient.Error.invalidResponse("lockdown QueryType returned an unknown service")
    }
    return type
  }

  public func getValue(
    domain: String? = nil,
    key: String? = nil,
    label: String = "stupid-app"
  ) throws -> Any {
    var options: [String: Any] = [:]
    if let domain { options["Domain"] = domain }
    if let key { options["Key"] = key }
    let response = try request(name: "GetValue", label: label, options: options)
    guard let value = response["Value"] else {
      throw USBMuxClient.Error.invalidResponse("lockdown GetValue omitted Value")
    }
    return value
  }

  public func setValue(
    _ value: Any,
    domain: String,
    key: String,
    label: String = "stupid-app"
  ) throws {
    _ = try request(
      name: "SetValue",
      label: label,
      options: ["Domain": domain, "Key": key, "Value": value]
    )
  }

  @discardableResult
  public func startSession(
    using pairRecord: LockdownPairRecord,
    label: String = "stupid-app"
  ) throws -> String {
    guard sessionID == nil else {
      throw USBMuxClient.Error.invalidInput("a lockdown session is already active")
    }
    let response = try request(
      name: "StartSession",
      label: label,
      options: ["HostID": pairRecord.hostID, "SystemBUID": pairRecord.systemBUID]
    )
    guard let newSessionID = response["SessionID"] as? String, !newSessionID.isEmpty else {
      throw USBMuxClient.Error.invalidResponse("lockdown StartSession omitted SessionID")
    }
    if (response["EnableSessionSSL"] as? Bool) == true {
      try connection.enableTLS(using: pairRecord)
    }
    sessionID = newSessionID
    return newSessionID
  }

  public func startService(
    _ name: String,
    includeEscrowBag: Bool = false,
    pairRecord: LockdownPairRecord,
    label: String = "stupid-app"
  ) throws -> LockdownService {
    guard sessionID != nil else {
      throw USBMuxClient.Error.invalidInput("start a lockdown session before starting a service")
    }
    guard !name.isEmpty else {
      throw USBMuxClient.Error.invalidInput("lockdown service name is empty")
    }
    var options: [String: Any] = ["Service": name]
    if includeEscrowBag {
      guard let escrowBag = pairRecord.escrowBag else {
        throw USBMuxClient.Error.invalidInput("pair record has no escrow bag")
      }
      options["EscrowBag"] = escrowBag
    }
    let response = try request(name: "StartService", label: label, options: options)
    guard
      let number = response["Port"] as? NSNumber,
      number.uint64Value > 0,
      number.uint64Value <= UInt16.max
    else {
      throw USBMuxClient.Error.invalidResponse("lockdown StartService omitted a valid Port")
    }
    return LockdownService(
      port: UInt16(number.uint64Value),
      enablesTLS: response["EnableServiceSSL"] as? Bool ?? false
    )
  }

  public func stopSession(label: String = "stupid-app") throws {
    guard let sessionID else { return }
    _ = try request(
      name: "StopSession",
      label: label,
      options: ["SessionID": sessionID]
    )
    self.sessionID = nil
  }

  func pair(
    record: [String: Any],
    hostName: String,
    timeoutSeconds: Double,
    label: String = "stupid-app"
  ) throws -> Data? {
    guard !record.isEmpty, !hostName.isEmpty else {
      throw USBMuxClient.Error.invalidInput("pairing metadata is incomplete")
    }
    guard timeoutSeconds > 0, timeoutSeconds.isFinite else {
      throw USBMuxClient.Error.invalidInput("pairing timeout must be positive")
    }
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while true {
      let response = try sendRequest(
        name: "Pair",
        label: label,
        options: [
          "HostName": hostName,
          "PairRecord": record,
          "ProtocolVersion": "2",
          "PairingOptions": ["ExtendedPairingErrors": true],
        ]
      )
      if response["Error"] as? String == "PairingDialogResponsePending" {
        guard Date() < deadline else { throw USBMuxClient.Error.timedOut }
        Thread.sleep(forTimeInterval: min(1, max(0, deadline.timeIntervalSinceNow)))
        continue
      }
      try validateResponse(response, request: "Pair")
      return response["EscrowBag"] as? Data
    }
  }

  private func request(
    name: String,
    label: String,
    options: [String: Any] = [:]
  ) throws -> [String: Any] {
    let response = try sendRequest(name: name, label: label, options: options)
    try validateResponse(response, request: name)
    return response
  }

  private func sendRequest(
    name: String,
    label: String,
    options: [String: Any]
  ) throws -> [String: Any] {
    var body: [String: Any] = ["Label": label, "Request": name]
    body.merge(options) { _, supplied in supplied }
    let payload = try PropertyListSerialization.data(
      fromPropertyList: body,
      format: .xml,
      options: 0
    )
    guard payload.count <= 16 * 1_024 * 1_024 else {
      throw USBMuxClient.Error.invalidInput("lockdown packet exceeds 16 MiB")
    }
    var length = UInt32(payload.count).bigEndian
    var packet = Data(bytes: &length, count: 4)
    packet.append(payload)
    try connection.write(packet)

    let responseHeader = try connection.read(count: 4)
    let responseLength = responseHeader.withUnsafeBytes { bytes in
      Int(UInt32(bigEndian: bytes.loadUnaligned(as: UInt32.self)))
    }
    guard (1...(16 * 1_024 * 1_024)).contains(responseLength) else {
      throw USBMuxClient.Error.malformedPacket("lockdown length is invalid")
    }
    let responseData = try connection.read(count: responseLength)
    guard
      let response = try PropertyListSerialization.propertyList(from: responseData, format: nil)
        as? [String: Any]
    else {
      throw USBMuxClient.Error.malformedPacket("lockdown payload is not a dictionary")
    }
    guard response["Request"] as? String == name else {
      throw USBMuxClient.Error.invalidResponse("lockdown response request does not match")
    }
    return response
  }

  private func validateResponse(_ response: [String: Any], request name: String) throws {
    if let error = response["Error"] as? String {
      throw USBMuxClient.Error.invalidResponse("lockdown rejected \(name): \(error)")
    }
    if response["Result"] as? String == "Failure" {
      throw USBMuxClient.Error.invalidResponse("lockdown rejected \(name)")
    }
  }
}

public final class LockdownServiceConnection: @unchecked Sendable {
  private let connection: SocketConnection

  init(connection: SocketConnection) {
    self.connection = connection
  }

  public func read(count: Int) throws -> Data {
    try connection.read(count: count)
  }

  public func write(_ data: Data) throws {
    try connection.write(data)
  }

  public func sendPlist(_ value: [String: Any]) throws {
    let payload = try PropertyListSerialization.data(
      fromPropertyList: value,
      format: .xml,
      options: 0
    )
    guard payload.count <= USBMuxClient.maximumPacketBytes else {
      throw USBMuxClient.Error.invalidInput("service plist exceeds 16 MiB")
    }
    var length = UInt32(payload.count).bigEndian
    var packet = Data(bytes: &length, count: 4)
    packet.append(payload)
    try connection.write(packet)
  }

  public func receivePlist() throws -> [String: Any] {
    let header = try connection.read(count: 4)
    let length = header.withUnsafeBytes {
      Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)))
    }
    guard (1...USBMuxClient.maximumPacketBytes).contains(length) else {
      throw USBMuxClient.Error.malformedPacket("service plist length is invalid")
    }
    let payload = try connection.read(count: length)
    guard
      let value = try PropertyListSerialization.propertyList(from: payload, format: nil)
        as? [String: Any]
    else {
      throw USBMuxClient.Error.malformedPacket("service plist is not a dictionary")
    }
    return value
  }

  public func close() {
    connection.closeImmediately()
  }

  /// Interrupts any blocked read or write by shutting the socket down without
  /// releasing the descriptor or any TLS state. Callers must join in-flight
  /// work before `close()`.
  public func cancel() {
    connection.cancel()
  }
}

final class SocketConnection: @unchecked Sendable {
  private var descriptor: Int32
  private var tls: OpaquePointer?
  private let timeoutMilliseconds: Int32

  init(address: String, timeoutSeconds: Double) throws {
    guard timeoutSeconds > 0, timeoutSeconds.isFinite else {
      throw USBMuxClient.Error.invalidInput("timeout must be positive")
    }
    guard timeoutSeconds * 1_000 <= Double(Int32.max) else {
      throw USBMuxClient.Error.invalidInput("timeout is too large")
    }
    timeoutMilliseconds = Int32(timeoutSeconds * 1_000)
    descriptor = try Self.connect(address: address)
    do {
      try Self.configure(descriptor: descriptor, timeoutSeconds: timeoutSeconds)
    } catch {
      close(descriptor)
      descriptor = -1
      throw error
    }
  }

  deinit {
    if let tls {
      stupid_app_lockdown_tls_destroy(tls)
    } else if descriptor >= 0 {
      close(descriptor)
    }
  }

  func closeImmediately() {
    if let activeTLS = tls {
      stupid_app_lockdown_tls_destroy(activeTLS)
      tls = nil
    }
    if descriptor >= 0 {
      shutdown(descriptor, Int32(SHUT_RDWR))
      close(descriptor)
      descriptor = -1
    }
  }

  func cancel() {
    if let activeTLS = tls {
      stupid_app_lockdown_tls_cancel(activeTLS)
    } else if descriptor >= 0 {
      shutdown(descriptor, Int32(SHUT_RDWR))
    }
  }

  func enableTLS(using pairRecord: LockdownPairRecord) throws {
    guard tls == nil, descriptor >= 0 else {
      throw USBMuxClient.Error.invalidInput("connection is already using TLS")
    }
    let socket = descriptor
    descriptor = -1
    var output: OpaquePointer?
    let result = pairRecord.hostCertificate.withUnsafeBytes { certificate in
      pairRecord.hostPrivateKey.withUnsafeBytes { privateKey in
        stupid_app_lockdown_tls_create(
          socket,
          certificate.bindMemory(to: UInt8.self).baseAddress,
          certificate.count,
          privateKey.bindMemory(to: UInt8.self).baseAddress,
          privateKey.count,
          timeoutMilliseconds,
          &output
        )
      }
    }
    guard result == STUPID_APP_LOCKDOWN_TLS_OK.rawValue, let output else {
      throw Self.tlsError(result)
    }
    tls = output
  }

  func read(count: Int) throws -> Data {
    guard count >= 0 else { throw USBMuxClient.Error.malformedPacket("negative read length") }
    guard count > 0 else { return Data() }
    var data = Data(count: count)
    if let tls {
      let result = data.withUnsafeMutableBytes { bytes in
        stupid_app_lockdown_tls_read(tls, bytes.bindMemory(to: UInt8.self).baseAddress, count)
      }
      guard result == STUPID_APP_LOCKDOWN_TLS_OK.rawValue else {
        throw Self.tlsError(result)
      }
      return data
    }
    var offset = 0
    while offset < count {
      let result = data.withUnsafeMutableBytes { bytes in
        recv(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset, 0)
      }
      if result > 0 {
        offset += result
      } else if result == 0 {
        throw USBMuxClient.Error.connectionClosed
      } else if errno == EINTR {
        continue
      } else if errno == EAGAIN || errno == EWOULDBLOCK {
        throw USBMuxClient.Error.timedOut
      } else {
        throw USBMuxClient.Error.connectionFailed(errno)
      }
    }
    return data
  }

  func write(_ data: Data) throws {
    guard !data.isEmpty else { return }
    if let tls {
      let result = data.withUnsafeBytes { bytes in
        stupid_app_lockdown_tls_write(tls, bytes.bindMemory(to: UInt8.self).baseAddress, data.count)
      }
      guard result == STUPID_APP_LOCKDOWN_TLS_OK.rawValue else {
        throw Self.tlsError(result)
      }
      return
    }
    var offset = 0
    while offset < data.count {
      #if os(Linux)
        let flags = Int32(MSG_NOSIGNAL)
      #else
        let flags: Int32 = 0
      #endif
      let result = data.withUnsafeBytes { bytes in
        send(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset, flags)
      }
      if result > 0 {
        offset += result
      } else if result < 0, errno == EINTR {
        continue
      } else if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        throw USBMuxClient.Error.timedOut
      } else {
        throw USBMuxClient.Error.connectionFailed(errno)
      }
    }
  }

  private static func tlsError(_ result: Int32) -> USBMuxClient.Error {
    if result == STUPID_APP_LOCKDOWN_TLS_TIMED_OUT.rawValue {
      return .timedOut
    }
    return .invalidResponse("lockdown TLS failed during phase \(result)")
  }

  private static func connect(address: String) throws -> Int32 {
    if address.hasPrefix("/") {
      return try connectUnix(path: address)
    }
    return try connectTCP(address: address)
  }

  private static func connectUnix(path: String) throws -> Int32 {
    #if os(Linux)
      let socketType = Int32(SOCK_STREAM.rawValue)
    #else
      let socketType = SOCK_STREAM
    #endif
    let descriptor = socket(AF_UNIX, socketType, 0)
    guard descriptor >= 0 else { throw USBMuxClient.Error.connectionFailed(errno) }
    var socketAddress = sockaddr_un()
    socketAddress.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    let capacity = MemoryLayout.size(ofValue: socketAddress.sun_path)
    guard bytes.count <= capacity else {
      close(descriptor)
      throw USBMuxClient.Error.invalidAddress
    }
    withUnsafeMutablePointer(to: &socketAddress.sun_path) { destination in
      destination.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
        path.withCString { source in
          _ = strncpy(destination, source, capacity - 1)
        }
      }
    }
    let result = withUnsafePointer(to: &socketAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        DarwinOrGlibc.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let code = errno
      close(descriptor)
      throw USBMuxClient.Error.connectionFailed(code)
    }
    return descriptor
  }

  private static func connectTCP(address: String) throws -> Int32 {
    let host: String
    let port: String
    if address.hasPrefix("["), let end = address.firstIndex(of: "]") {
      host = String(address[address.index(after: address.startIndex)..<end])
      let suffix = address[address.index(after: end)...]
      guard suffix.first == ":" else { throw USBMuxClient.Error.invalidAddress }
      port = String(suffix.dropFirst())
    } else {
      guard let separator = address.lastIndex(of: ":") else {
        throw USBMuxClient.Error.invalidAddress
      }
      host = String(address[..<separator])
      port = String(address[address.index(after: separator)...])
    }
    guard !host.isEmpty, UInt16(port) != nil else { throw USBMuxClient.Error.invalidAddress }

    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    #if os(Linux)
      hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    #else
      hints.ai_socktype = SOCK_STREAM
    #endif
    hints.ai_protocol = Int32(IPPROTO_TCP)
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, port, &hints, &result) == 0, let first = result else {
      throw USBMuxClient.Error.invalidAddress
    }
    defer { freeaddrinfo(result) }
    var current: UnsafeMutablePointer<addrinfo>? = first
    var lastError = Int32(ECONNREFUSED)
    while let info = current?.pointee {
      let descriptor = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
      if descriptor >= 0 {
        if DarwinOrGlibc.connect(descriptor, info.ai_addr, info.ai_addrlen) == 0 {
          return descriptor
        }
        lastError = errno
        close(descriptor)
      }
      current = info.ai_next
    }
    throw USBMuxClient.Error.connectionFailed(lastError)
  }

  private static func configure(descriptor: Int32, timeoutSeconds: Double) throws {
    let whole = floor(timeoutSeconds)
    var timeout = timeval()
    timeout.tv_sec = numericCast(Int(whole))
    timeout.tv_usec = numericCast(Int((timeoutSeconds - whole) * 1_000_000))
    let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
    guard
      setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize) == 0,
      setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize) == 0
    else {
      throw USBMuxClient.Error.connectionFailed(errno)
    }
    #if canImport(Darwin)
      var enabled: Int32 = 1
      guard
        setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_NOSIGPIPE,
          &enabled,
          socklen_t(MemoryLayout<Int32>.size)
        ) == 0
      else {
        throw USBMuxClient.Error.connectionFailed(errno)
      }
    #endif
  }
}

private enum DarwinOrGlibc {
  static func connect(
    _ descriptor: Int32,
    _ address: UnsafePointer<sockaddr>?,
    _ length: socklen_t
  ) -> Int32 {
    #if canImport(Darwin)
      Darwin.connect(descriptor, address, length)
    #elseif canImport(Glibc)
      Glibc.connect(descriptor, address, length)
    #endif
  }
}
