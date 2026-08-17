import Foundation
import Testing
import _CryptoExtras

@testable import DeviceKit

struct USBMuxClientTests {
  @Test("encodes the usbmux plist envelope with a length-inclusive little-endian header")
  func packetEncoding() throws {
    let packet = try USBMuxClient.encodePacket(
      body: USBMuxClient.withClientMetadata(["MessageType": "ReadBUID"]),
      tag: 42
    )
    let header = try USBMuxClient.decodeHeader(Data(packet.prefix(16)))
    #expect(header.length == packet.count)
    #expect(header.version == 1)
    #expect(header.message == 8)
    #expect(header.tag == 42)
    let body = try #require(
      PropertyListSerialization.propertyList(from: packet.dropFirst(16), format: nil)
        as? [String: Any]
    )
    #expect(body["MessageType"] as? String == "ReadBUID")
    #expect(body["ProgName"] as? String == "stupid-app")
  }

  @Test("rejects malformed usbmux packet lengths and result codes")
  func malformedPackets() throws {
    var header = Data(repeating: 0, count: 16)
    header[0] = 15
    #expect(throws: USBMuxClient.Error.self) {
      try USBMuxClient.decodeHeader(header)
    }
    #expect(throws: USBMuxClient.Error.muxResult(3)) {
      try USBMuxClient.validateResult(["MessageType": "Result", "Number": 3])
    }
  }

  @Test("lists only USB devices through fragmented usbmux responses")
  func listDevices() throws {
    let server = try FakeUSBMuxServer { request in
      #expect(request["MessageType"] as? String == "ListDevices")
      return [
        "DeviceList": [
          [
            "MessageType": "Attached",
            "DeviceID": 7,
            "Properties": ["SerialNumber": "test-usb-udid", "ConnectionType": "USB"],
          ],
          [
            "MessageType": "Attached",
            "DeviceID": 8,
            "Properties": ["SerialNumber": "test-network-udid", "ConnectionType": "Network"],
          ],
        ]
      ]
    }
    defer { server.stop() }
    let client = USBMuxClient(address: "127.0.0.1:\(server.port)", timeoutSeconds: 2)
    #expect(try client.usbDeviceUDIDs() == ["test-usb-udid"])
  }

  @Test("times out when usbmuxd does not complete a response")
  func timeout() throws {
    let server = try FakeUSBMuxServer(responseDelay: 0.25) { _ in
      ["BUID": "too-late"]
    }
    defer { server.stop() }
    #expect(throws: USBMuxClient.Error.timedOut) {
      _ = try USBMuxClient(
        address: "127.0.0.1:\(server.port)",
        timeoutSeconds: 0.05
      ).readBUID()
    }
  }

  @Test("reads and saves pair records without decoding their secret contents")
  func pairRecords() throws {
    let record = try PropertyListSerialization.data(
      fromPropertyList: ["HostID": "sanitized-host"],
      format: .xml,
      options: 0
    )
    let readServer = try FakeUSBMuxServer { request in
      #expect(request["MessageType"] as? String == "ReadPairRecord")
      #expect(request["PairRecordID"] as? String == "sanitized-device")
      return ["PairRecordData": record]
    }
    #expect(
      try USBMuxClient(address: "127.0.0.1:\(readServer.port)")
        .readPairRecord(identifier: "sanitized-device") == record
    )
    readServer.stop()

    let saveServer = try FakeUSBMuxServer { request in
      #expect(request["MessageType"] as? String == "SavePairRecord")
      #expect(request["PairRecordData"] as? Data == record)
      return ["MessageType": "Result", "Number": 0]
    }
    defer { saveServer.stop() }
    try USBMuxClient(address: "127.0.0.1:\(saveServer.port)").savePairRecord(
      identifier: "sanitized-device",
      deviceID: 9,
      data: record
    )
  }

  @Test("connects to lockdown and uses its big-endian body-length framing")
  func lockdownQuery() throws {
    let server = try FakeUSBMuxServer(
      usbmuxResponse: { request in
        #expect(request["MessageType"] as? String == "Connect")
        #expect((request["PortNumber"] as? NSNumber)?.uint16Value == UInt16(bigEndian: 62_078))
        return ["MessageType": "Result", "Number": 0]
      },
      lockdownResponse: { request in
        #expect(request["Request"] as? String == "QueryType")
        return ["Request": "QueryType", "Type": LockdownClient.serviceType]
      }
    )
    defer { server.stop() }
    let lockdown = try USBMuxClient(address: "127.0.0.1:\(server.port)")
      .connectLockdown(deviceID: 4)
    #expect(try lockdown.queryType() == LockdownClient.serviceType)
  }

  @Test("decodes required pair-record credentials")
  func pairRecordCredentials() throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: [
        "HostID": "sanitized-host",
        "SystemBUID": "sanitized-system",
        "HostCertificate": Data("certificate".utf8),
        "HostPrivateKey": Data("private-key".utf8),
        "EscrowBag": Data("escrow".utf8),
      ],
      format: .xml,
      options: 0
    )
    let record = try LockdownPairRecord(data: data)
    #expect(record.hostID == "sanitized-host")
    #expect(record.systemBUID == "sanitized-system")
    #expect(record.escrowBag == Data("escrow".utf8))
  }

  @Test("starts a session and service before stopping the session")
  func lockdownSessionAndService() throws {
    let pairRecord = try LockdownPairRecord(
      data: PropertyListSerialization.data(
        fromPropertyList: [
          "HostID": "sanitized-host",
          "SystemBUID": "sanitized-system",
          "HostCertificate": Data("certificate".utf8),
          "HostPrivateKey": Data("private-key".utf8),
          "EscrowBag": Data("escrow".utf8),
        ],
        format: .xml,
        options: 0
      )
    )
    let server = try FakeUSBMuxServer(
      usbmuxResponse: { _ in ["MessageType": "Result", "Number": 0] },
      lockdownResponses: [
        { request in
          #expect(request["Request"] as? String == "StartSession")
          #expect(request["HostID"] as? String == "sanitized-host")
          return [
            "Request": "StartSession", "SessionID": "sanitized-session",
            "EnableSessionSSL": false,
          ]
        },
        { request in
          #expect(request["Request"] as? String == "StartService")
          #expect(request["Service"] as? String == "com.apple.afc")
          #expect(request["EscrowBag"] as? Data == Data("escrow".utf8))
          return ["Request": "StartService", "Port": 12_345, "EnableServiceSSL": false]
        },
        { request in
          #expect(request["Request"] as? String == "StopSession")
          #expect(request["SessionID"] as? String == "sanitized-session")
          return ["Request": "StopSession", "Result": "Success"]
        },
      ]
    )
    defer { server.stop() }
    let lockdown = try USBMuxClient(address: "127.0.0.1:\(server.port)")
      .connectLockdown(deviceID: 4)
    #expect(try lockdown.startSession(using: pairRecord) == "sanitized-session")
    #expect(
      try lockdown.startService("com.apple.afc", includeEscrowBag: true, pairRecord: pairRecord)
        == LockdownService(port: 12_345, enablesTLS: false)
    )
    try lockdown.stopSession()
  }

  @Test("generates a complete native lockdown pair record")
  func pairingMaterial() throws {
    let deviceKey = try _RSA.Signing.PrivateKey(keySize: .bits2048)
    let material = try PairingMaterial(
      devicePublicKeyPEM: Data(deviceKey.publicKey.pemRepresentation.utf8),
      systemBUID: "sanitized-system",
      wifiAddress: "00:00:00:00:00:00"
    )
    #expect(material.requestRecord["HostPrivateKey"] == nil)
    #expect(material.requestRecord["RootPrivateKey"] as? Data != nil)
    let stored = try material.serializedRecord(escrowBag: Data("escrow".utf8))
    let record = try LockdownPairRecord(data: stored)
    #expect(record.systemBUID == "sanitized-system")
    #expect(record.escrowBag == Data("escrow".utf8))
  }

  @Test("connects to an optional live usbmuxd socket")
  func liveUsbmuxd() throws {
    guard let address = ProcessInfo.processInfo.environment["NATIVE_USBMUX_ADDRESS"] else {
      return
    }
    let client = USBMuxClient(address: address)
    let buid = try client.readBUID()
    #expect(!buid.isEmpty)
    let devices = try client.devices()
    guard ProcessInfo.processInfo.environment["NATIVE_USBMUX_REQUIRE_DEVICE"] == "1" else {
      return
    }
    let device = try #require(devices.filter { $0.connectionType == .usb }.only)
    let lockdown = try client.connectLockdown(deviceID: device.deviceID)
    #expect(try lockdown.queryType() == LockdownClient.serviceType)
    let uniqueDeviceID = try #require(lockdown.getValue(key: "UniqueDeviceID") as? String)
    #expect(!uniqueDeviceID.isEmpty)
    if ProcessInfo.processInfo.environment["NATIVE_USBMUX_PAIR"] == "1" {
      let result = try LockdownPairer(address: address).pair(
        udid: device.serialNumber,
        replaceExistingRecord: ProcessInfo.processInfo.environment[
          "NATIVE_USBMUX_REPLACE_PAIR_RECORD"] == "1"
      )
      #expect(
        result
          == (ProcessInfo.processInfo.environment["NATIVE_USBMUX_REPLACE_PAIR_RECORD"] == "1"
            ? .createdRecord : .reusedExistingRecord)
      )
    }
    guard ProcessInfo.processInfo.environment["NATIVE_USBMUX_START_AFC"] == "1" else {
      return
    }
    let pairRecordData = try client.readPairRecord(identifier: device.serialNumber)
    let pairRecord = try #require(pairRecordData)
    let credentials = try LockdownPairRecord(data: pairRecord)
    _ = try lockdown.startSession(using: credentials)
    let service = try lockdown.startService(
      "com.apple.afc",
      pairRecord: credentials
    )
    _ = try client.connectService(
      deviceID: device.deviceID,
      service: service,
      pairRecord: credentials
    )
    try lockdown.stopSession()
  }
}

extension LockdownPairer {
  fileprivate init(address: String) {
    self.init(
      usbmuxAddress: address,
      pairingDirectory: ProcessInfo.processInfo.environment["NATIVE_PAIRING_DIRECTORY"]
        .map { URL(fileURLWithPath: $0) },
      timeoutSeconds: 60,
      progress: { print($0) }
    )
  }
}

extension Collection {
  fileprivate var only: Element? {
    count == 1 ? first : nil
  }
}

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

private final class FakeUSBMuxServer: @unchecked Sendable {
  let port: Int
  private let descriptor: Int32
  private let queue = DispatchQueue(label: "stupid-app.tests.usbmux")

  convenience init(
    responseDelay: TimeInterval = 0,
    response: @escaping @Sendable ([String: Any]) -> [String: Any]
  ) throws {
    try self.init(usbmuxResponse: response, responseDelay: responseDelay)
  }

  convenience init(
    usbmuxResponse: @escaping @Sendable ([String: Any]) -> [String: Any],
    lockdownResponse: (@Sendable ([String: Any]) -> [String: Any])? = nil,
    responseDelay: TimeInterval = 0
  ) throws {
    try self.init(
      usbmuxResponse: usbmuxResponse,
      lockdownResponses: lockdownResponse.map { [$0] } ?? [],
      responseDelay: responseDelay
    )
  }

  init(
    usbmuxResponse: @escaping @Sendable ([String: Any]) -> [String: Any],
    lockdownResponses: [@Sendable ([String: Any]) -> [String: Any]],
    responseDelay: TimeInterval = 0
  ) throws {
    #if os(Linux)
      let socketType = Int32(SOCK_STREAM.rawValue)
    #else
      let socketType = SOCK_STREAM
    #endif
    let socketDescriptor = socket(AF_INET, socketType, 0)
    guard socketDescriptor >= 0 else { throw ServerError.setup }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0, listen(socketDescriptor, 1) == 0 else {
      close(socketDescriptor)
      throw ServerError.setup
    }
    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(socketDescriptor, $0, &length)
      }
    }
    guard nameResult == 0 else {
      close(socketDescriptor)
      throw ServerError.setup
    }
    descriptor = socketDescriptor
    port = Int(UInt16(bigEndian: bound.sin_port))
    queue.async { [descriptor] in
      let client = accept(descriptor, nil, nil)
      guard client >= 0 else { return }
      defer { close(client) }
      #if canImport(Darwin)
        var enabled: Int32 = 1
        _ = setsockopt(
          client,
          SOL_SOCKET,
          SO_NOSIGPIPE,
          &enabled,
          socklen_t(MemoryLayout<Int32>.size)
        )
      #endif
      do {
        let headerData = try Self.read(client, count: 16)
        let header = try USBMuxClient.decodeHeader(headerData)
        let payload = try Self.read(client, count: header.length - 16)
        let request = try #require(
          PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any]
        )
        if responseDelay > 0 {
          Thread.sleep(forTimeInterval: responseDelay)
        }
        let packet = try USBMuxClient.encodePacket(body: usbmuxResponse(request), tag: header.tag)
        for byte in packet {
          var value = byte
          _ = withUnsafeBytes(of: &value) { send(client, $0.baseAddress, 1, 0) }
        }
        for lockdownResponse in lockdownResponses {
          let lengthData = try Self.read(client, count: 4)
          let bodyLength = lengthData.withUnsafeBytes {
            Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)))
          }
          let bodyData = try Self.read(client, count: bodyLength)
          let body = try #require(
            PropertyListSerialization.propertyList(from: bodyData, format: nil)
              as? [String: Any]
          )
          let output = try PropertyListSerialization.data(
            fromPropertyList: lockdownResponse(body),
            format: .xml,
            options: 0
          )
          var outputLength = UInt32(output.count).bigEndian
          _ = withUnsafeBytes(of: &outputLength) {
            send(client, $0.baseAddress, $0.count, 0)
          }
          _ = output.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
        }
      } catch {}
    }
  }

  func stop() {
    shutdown(descriptor, Int32(SHUT_RDWR))
    close(descriptor)
  }

  private static func read(_ descriptor: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let result = data.withUnsafeMutableBytes {
        recv(descriptor, $0.baseAddress!.advanced(by: offset), count - offset, 0)
      }
      guard result > 0 else { throw ServerError.setup }
      offset += result
    }
    return data
  }

  enum ServerError: Error {
    case setup
  }
}
