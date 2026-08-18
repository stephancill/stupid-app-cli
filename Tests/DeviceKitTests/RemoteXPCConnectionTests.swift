import Foundation
import Testing

@testable import DeviceKit

struct RemoteXPCConnectionTests {
  @Test("RSD client performs the handshake and resolves peer info and services")
  func rsdHandshakeAndPeerInfo() async throws {
    let server = try FakeRemoteXPCServer(
      peerInfo: .dictionary([
        "Properties": .dictionary([
          "UniqueDeviceID": .string("udid-0001"),
          "ProductType": .string("iPhone15,2"),
          "OSVersion": .string("26.1"),
          "BuildVersion": .string("1A1"),
          "UniqueChipID": .uint64(42),
        ]),
        "Services": .dictionary([
          "com.apple.coredevice.appservice": .dictionary([
            "Port": .uint64(6000)
          ]),
          "com.apple.mobile.installation_proxy": .dictionary([
            "Port": .uint64(6001)
          ]),
        ]),
      ])
    )
    defer { server.stop() }

    let client = RSDClient(host: "127.0.0.1", port: server.port, timeoutSeconds: 5)
    let peerInfo = try client.connect()
    #expect(peerInfo.udid == "udid-0001")
    #expect(peerInfo.productType == "iPhone15,2")
    #expect(peerInfo.services["com.apple.coredevice.appservice"]?.port == 6000)
    #expect(peerInfo.services["com.apple.mobile.installation_proxy"]?.port == 6001)
    try await waitForHandshake(server)
  }

  @Test("RSD peer info accepts service ports encoded as strings and skips invalids")
  func peerInfoStringPorts() async throws {
    let server = try FakeRemoteXPCServer(
      peerInfo: .dictionary([
        "Properties": .dictionary([
          "UniqueDeviceID": .string("udid-0002"),
          "ProductType": .string("iPhone16,1"),
        ]),
        "Services": .dictionary([
          // The device serializes RSD service ports as strings.
          "com.apple.coredevice.appservice": .dictionary([
            "Port": .string("58198")
          ]),
          // A service without a usable port is skipped, not a hard failure.
          "com.apple.internal.dt.remote.debugproxy": .dictionary([
            "Port": .string("0")
          ]),
          "com.apple.mobile.installation_proxy": .dictionary([
            "Port": .uint64(6001)
          ]),
        ]),
      ])
    )
    defer { server.stop() }

    let client = RSDClient(host: "127.0.0.1", port: server.port, timeoutSeconds: 5)
    let peerInfo = try client.connect()
    #expect(peerInfo.udid == "udid-0002")
    #expect(peerInfo.services["com.apple.coredevice.appservice"]?.port == 58198)
    #expect(peerInfo.services["com.apple.mobile.installation_proxy"]?.port == 6001)
    #expect(peerInfo.services["com.apple.internal.dt.remote.debugproxy"] == nil)
  }

  @Test("AppService client launches an application over RemoteXPC")
  func appServiceLaunch() async throws {
    let launchResponseHex =
      "920bb0290101000098000000000000000100000000000000423713420500000000f000008800000002000000436f72654465766963652e6f757470757400000000f000004c0000000100000070726f63657373546f6b656e7300000000e00000300000000100000000f00000240000000100000070726f636573734964656e74696669657200000000300000d204000000000000436f72654465766963652e72657475726e56616c7565000000100000"

    // The RSD and appservice connections share the fake server port so the
    // accept loop can serve both from one listener.
    let server = try FakeRemoteXPCServer.withAppServicePeerInfo(
      serviceName: AppServiceClient.serviceName,
      serviceResponses: [Data(hexString: launchResponseHex)]
    )
    defer { server.stop() }

    let client = RSDClient(host: "127.0.0.1", port: server.port, timeoutSeconds: 5)
    let peerInfo = try client.connect()
    let service = try client.connect(service: AppServiceClient.serviceName, peerInfo: peerInfo)
    let app = AppServiceClient(service: service)
    let pid = try app.launchApplication(bundleID: "net.stupidtech.acceptance-app")
    #expect(pid == 1234)
    try await waitForServiceRequest(server)
    #expect(
      server.lastServiceRequest?.dictionaryValue?["CoreDevice.featureIdentifier"]
        == .string(AppServiceClient.launchFeature)
    )
  }

  @Test("rejects a peer that closes without peer info")
  func peerClosed() async throws {
    let server = try FakeRemoteXPCServer(peerInfo: nil)
    defer { server.stop() }
    let client = RSDClient(host: "127.0.0.1", port: server.port, timeoutSeconds: 2)
    do {
      _ = try client.connect()
      Issue.record("Expected the peer-close exchange to fail")
    } catch {
      // Any terminal error is acceptable; the peer simply closed.
    }
  }

  @Test("CoreDevice tunnel service parses ServiceVersion and the pairing handshake")
  func tunnelServiceConnect() async throws {
    let server = try FakeRemoteXPCServer.withTunnelService(
      deviceIdentifier: "DEVICE-RP-ID-0001")
    defer { server.stop() }

    let client = RSDClient(host: "127.0.0.1", port: server.port, timeoutSeconds: 5)
    let peerInfo = try client.connect()
    let service = try client.connect(
      service: CoreDeviceTunnelService.serviceName, peerInfo: peerInfo)
    let tunnelService = CoreDeviceTunnelService(service: service)
    try tunnelService.connect()

    #expect(tunnelService.deviceIdentifier == "DEVICE-RP-ID-0001")
    #expect(tunnelService.deviceModel == "iPhone15,2")
    #expect(tunnelService.nextSequenceNumber == 1)
    try await waitForTunnelServiceRequest(server)

    let request = try #require(server.lastTunnelServiceRequest?.dictionaryValue)
    // The envelope is wrapped in the mangled type name.
    #expect(
      request["mangledTypeName"]
        == .string("RemotePairing.ControlChannelMessageEnvelope"))
    let envelope = request["value"]?.dictionaryValue
    #expect(envelope?["originatedBy"] == .string("host"))
    let plain = envelope?["message"]?.dictionaryValue?["plain"]?.dictionaryValue
    let inner = plain?["_0"]?.dictionaryValue
    let handshake = inner?["request"]?.dictionaryValue?["_0"]?.dictionaryValue?["handshake"]?
      .dictionaryValue?["_0"]?.dictionaryValue
    #expect(handshake?["wireProtocolVersion"] == .int64(19))
    #expect(
      handshake?["hostOptions"]?.dictionaryValue?["attemptPairVerify"] == .bool(true))
  }

  @Test("AppService launch rejects output without a process identifier")
  func missingProcessID() throws {
    let value: XPCValue = .dictionary([
      "CoreDevice.output": .dictionary([
        "processTokens": .array([])
      ])
    ])
    #expect(throws: AppServiceClient.Error.noProcessIdentifier) {
      _ = try AppServiceClient.processIdentifier(from: value)
    }
    #expect(throws: AppServiceClient.Error.missingOutput) {
      _ = try AppServiceClient.processIdentifier(from: .dictionary([:]))
    }
  }

  private func waitForHandshake(_ server: FakeRemoteXPCServer) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !server.handshakeSucceeded {
      guard ContinuousClock.now < deadline else {
        Issue.record("The fake RSD server did not complete the handshake")
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func waitForServiceRequest(_ server: FakeRemoteXPCServer) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while server.lastServiceRequest == nil {
      guard ContinuousClock.now < deadline else {
        Issue.record("The fake RSD server did not receive a service request")
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func waitForTunnelServiceRequest(_ server: FakeRemoteXPCServer) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while server.lastTunnelServiceRequest == nil {
      guard ContinuousClock.now < deadline else {
        Issue.record("The fake server did not receive the tunnel-service handshake")
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
}

extension Data {
  init(hexString: String) {
    self.init()
    var index = hexString.startIndex
    while index < hexString.endIndex {
      let next = hexString.index(index, offsetBy: 2)
      append(UInt8(hexString[index..<next], radix: 16)!)
      index = next
    }
  }
}

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Minimal RemoteXPC HTTP/2 server that performs the handshake, pushes
/// peer_info on the reply channel, and answers RemoteXPC requests on the root
/// channel with a synthetic CoreDevice output.
private final class FakeRemoteXPCServer: @unchecked Sendable {
  let port: Int
  private let state: State

  private let descriptor: Int32
  private let queue = DispatchQueue(label: "stupid-app.tests.remotexpc")

  convenience init(
    peerInfo: XPCValue? = nil,
    serviceResponses: [Data] = []
  ) throws {
    try self.init(
      peerInfoBuilder: { _ in peerInfo },
      serviceResponses: serviceResponses
    )
  }

  /// Binds the listener first, then builds peer info advertising the real port
  /// for the appservice service so the second connection can reuse the socket.
  static func withAppServicePeerInfo(
    serviceName: String,
    serviceResponses: [Data]
  ) throws -> FakeRemoteXPCServer {
    try FakeRemoteXPCServer(
      peerInfoBuilder: { port in
        .dictionary([
          "Properties": .dictionary([
            "UniqueDeviceID": .string("udid-0001"),
            "ProductType": .string("iPhone15,2"),
            "OSVersion": .string("26.1"),
          ]),
          "Services": .dictionary([
            serviceName: .dictionary([
              "Port": .uint64(UInt64(port))
            ])
          ]),
        ])
      },
      serviceResponses: serviceResponses
    )
  }

  /// Advertises the CoreDevice tunnel service and scripts its ServiceVersion
  /// push plus the attemptPairVerify handshake response.
  static func withTunnelService(deviceIdentifier: String) throws -> FakeRemoteXPCServer {
    let handshakeValue: XPCValue = .dictionary([
      "mangledTypeName": .string("RemotePairing.ControlChannelMessageEnvelope"),
      "value": .dictionary([
        "message": .dictionary([
          "plain": .dictionary([
            "_0": .dictionary([
              "response": .dictionary([
                "_1": .dictionary([
                  "handshake": .dictionary([
                    "_0": .dictionary([
                      "peerDeviceInfo": .dictionary([
                        "identifier": .string(deviceIdentifier),
                        "model": .string("iPhone15,2"),
                      ])
                    ])
                  ])
                ])
              ])
            ])
          ])
        ])
      ]),
    ])
    return try FakeRemoteXPCServer(
      peerInfoBuilder: { port in
        .dictionary([
          "Properties": .dictionary([
            "UniqueDeviceID": .string("udid-0001"),
            "ProductType": .string("iPhone15,2"),
            "OSVersion": .string("26.1"),
          ]),
          "Services": .dictionary([
            CoreDeviceTunnelService.serviceName: .dictionary([
              "Port": .uint64(UInt64(port))
            ])
          ]),
        ])
      },
      serviceResponses: [],
      tunnelService: (
        serviceVersion: try XPCCodec.encodeWrapper(
          value: .dictionary(["ServiceVersion": .int64(19)]),
          messageID: 2,
          flags: 0x0101),
        handshakeResponse: try XPCCodec.encodeWrapper(
          value: handshakeValue,
          messageID: 1,
          flags: 0x0101)
      )
    )
  }

  init(
    peerInfoBuilder: (Int) -> XPCValue?,
    serviceResponses: [Data],
    tunnelService: (serviceVersion: Data, handshakeResponse: Data)? = nil
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

    let peerInfoBytes: Data?
    if let value = peerInfoBuilder(port) {
      peerInfoBytes = try XPCCodec.encodeWrapper(value: value, messageID: 2, flags: 0x101)
    } else {
      peerInfoBytes = nil
    }

    let state = State(
      peerInfo: peerInfoBytes,
      serviceResponses: serviceResponses,
      tunnelService: tunnelService
    )
    self.state = state
    queue.async { [descriptor] in
      var connectionCount = 0
      while true {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { break }
        defer { close(client) }
        do {
          try Self.runServer(client: client, state: state, connectionIndex: connectionCount)
        } catch {}
        connectionCount += 1
        let servedServices = connectionCount - 1
        if state.tunnelService != nil, servedServices >= 1 {
          break
        }
        if state.serviceResponses.isEmpty, state.tunnelService == nil, connectionCount >= 1 {
          break
        }
      }
    }
  }

  var handshakeSucceeded: Bool {
    state.handshakeSucceeded
  }

  var lastServiceRequest: XPCValue? {
    state.lastServiceRequest
  }

  var lastTunnelServiceRequest: XPCValue? {
    state.lastTunnelServiceRequest
  }

  func stop() {
    shutdown(descriptor, Int32(SHUT_RDWR))
    close(descriptor)
  }

  private final class State: @unchecked Sendable {
    let peerInfo: Data?
    let serviceResponses: [Data]
    let tunnelService: (serviceVersion: Data, handshakeResponse: Data)?
    let lock = NSLock()
    var handshakeSucceeded = false
    var lastServiceRequest: XPCValue?
    var lastTunnelServiceRequest: XPCValue?

    init(
      peerInfo: Data?,
      serviceResponses: [Data],
      tunnelService: (serviceVersion: Data, handshakeResponse: Data)?
    ) {
      self.peerInfo = peerInfo
      self.serviceResponses = serviceResponses
      self.tunnelService = tunnelService
    }

    func setHandshakeSucceeded(_ value: Bool) {
      lock.lock()
      handshakeSucceeded = value
      lock.unlock()
    }

    func setLastServiceRequest(_ value: XPCValue?) {
      lock.lock()
      lastServiceRequest = value
      lock.unlock()
    }

    func setLastTunnelServiceRequest(_ value: XPCValue?) {
      lock.lock()
      lastTunnelServiceRequest = value
      lock.unlock()
    }
  }

  private static func runServer(client: Int32, state: State, connectionIndex: Int) throws {
    // Read the client's HTTP/2 preface and handshake frames.
    let magic = try read(client, count: HTTP2Frame.magic.count)
    guard magic == HTTP2Frame.magic else { throw ServerError.handshake }
    // Read the client's SETTINGS frame.
    _ = try readFrame(client)
    // Read the client's WINDOW_UPDATE, HEADERS, and initial DATA frames.
    _ = try readFrame(client)
    _ = try readFrame(client)
    let emptyRequest = try readFrame(client)
    guard emptyRequest.kind == .data else { throw ServerError.handshake }
    let keepAlive = try readFrame(client)
    guard keepAlive.kind == .data else { throw ServerError.handshake }
    let headersReply = try readFrame(client)
    guard headersReply.kind == .headers else { throw ServerError.handshake }
    let replyHandshake = try readFrame(client)
    guard replyHandshake.kind == .data else { throw ServerError.handshake }
    state.setHandshakeSucceeded(true)

    // Reply with our own SETTINGS and await the ACK.
    try write(
      client,
      HTTP2Frame.settingsFrame(pairs: [
        (id: 0x3, value: 100),
        (id: 0x4, value: 1_048_576),
      ]))
    let settingsAck = try readFrame(client)
    guard settingsAck.kind == .settings else { throw ServerError.handshake }

    if connectionIndex == 0 {
      if let peerInfo = state.peerInfo {
        try write(client, HTTP2Frame.dataFrame(streamID: 3, payload: peerInfo))
      }
      // Keep reading until the peer closes.
      _ = try? readFrame(client)
      return
    }

    if let tunnelService = state.tunnelService, connectionIndex == 1 {
      // Push ServiceVersion, then answer the attemptPairVerify handshake.
      try write(
        client, HTTP2Frame.dataFrame(streamID: 3, payload: tunnelService.serviceVersion))
      let request = try readFrame(client)
      if request.kind == .data, let value = try? XPCCodec.decodeWrapper(request.payload).value {
        state.setLastTunnelServiceRequest(value)
      }
      try write(
        client, HTTP2Frame.dataFrame(streamID: 1, payload: tunnelService.handshakeResponse))
      _ = try? readFrame(client)
      return
    }

    let responseIndex = connectionIndex - 1
    guard state.serviceResponses.indices.contains(responseIndex) else {
      return
    }
    // Wait for the request DATA frame, then reply on stream 1.
    let request = try readFrame(client)
    if request.kind == .data, let value = try? XPCCodec.decodeWrapper(request.payload).value {
      state.setLastServiceRequest(value)
    }
    try write(
      client, HTTP2Frame.dataFrame(streamID: 1, payload: state.serviceResponses[responseIndex]))
    // Keep reading until the peer closes.
    _ = try? readFrame(client)
  }

  private static func readFrame(_ client: Int32) throws -> (kind: HTTP2Frame.Kind, payload: Data) {
    let header = try read(client, count: 9)
    let decoded = try HTTP2Frame.decodeHeader(header)
    let payload = decoded.length > 0 ? try read(client, count: decoded.length) : Data()
    return (decoded.kind, payload)
  }

  private static func read(_ client: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let result = data.withUnsafeMutableBytes {
        recv(client, $0.baseAddress!.advanced(by: offset), count - offset, 0)
      }
      guard result > 0 else { throw ServerError.setup }
      offset += result
    }
    return data
  }

  private static func write(_ client: Int32, _ data: Data) throws {
    var offset = 0
    while offset < data.count {
      let result = data.withUnsafeBytes {
        #if canImport(Darwin)
          send(client, $0.baseAddress!.advanced(by: offset), data.count - offset, 0)
        #else
          send(
            client, $0.baseAddress!.advanced(by: offset), data.count - offset, Int32(MSG_NOSIGNAL))
        #endif
      }
      guard result > 0 else { throw ServerError.setup }
      offset += result
    }
  }

  enum ServerError: Error {
    case setup
    case handshake
  }
}
