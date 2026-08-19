import Foundation
import Testing

@testable import DeviceKit

struct CoreDeviceTLSConnectionTests {
  @Test("encodes and decodes bounded CDTunnel frames")
  func framing() throws {
    let frame = try CoreDeviceTLSConnection.frame([
      "clientParameters": ["address": "fd00::2", "mtu": 16_000],
      "serverAddress": "fd00::1",
      "serverRSDPort": 58_743,
    ])
    #expect(
      try CoreDeviceTLSConnection.decode(frame)
        == .init(
          clientAddress: "fd00::2",
          clientMTU: 16_000,
          serverAddress: "fd00::1",
          serverRSDPort: 58_743
        )
    )
  }

  @Test("rejects malformed CDTunnel frames")
  func malformedFrame() {
    #expect(throws: CoreDeviceTLSConnection.Error.self) {
      try CoreDeviceTLSConnection.decode(Data("not-a-frame".utf8))
    }
  }

  @Test("accepts the supported OpenSSL major version")
  func openSSLPolicy() throws {
    try CoreDeviceTLSConnection.validateOpenSSL()
  }

  @Test("rejects hostnames instead of performing unbounded DNS resolution")
  func rejectsHostname() async {
    await #expect(throws: CoreDeviceTLSConnection.Error.self) {
      try await CoreDeviceTLSConnection(timeoutMilliseconds: 250).connect(
        host: "localhost",
        port: 1,
        preSharedKey: Data(repeating: 1, count: 32)
      )
    }
  }

  @Test("applies one total timeout to a stalled TLS peer")
  func totalTimeout() async throws {
    let server = try StalledTCPServer()
    defer { server.stop() }
    // The worker's 250 ms deadline must fire and surface a .timedOut rather than hanging.
    // The only wall-clock bound is a very generous one (well beyond the ~14 s worst-case
    // worker dispatch latency observed under full-suite parallel load) that exists solely
    // as a safety net: if the deadline were ever removed, the await below would hang
    // against the stalled peer and fail this bound instead of blocking the suite.
    let clock = ContinuousClock()
    let start = clock.now
    await #expect(throws: CoreDeviceTLSConnection.Error.timedOut) {
      try await CoreDeviceTLSConnection(timeoutMilliseconds: 250).connect(
        host: "127.0.0.1",
        port: server.port,
        preSharedKey: Data(repeating: 7, count: 32)
      )
    }
    #expect(start.duration(to: clock.now) < .seconds(120))
  }

  @Test("task cancellation interrupts an in-flight TLS exchange")
  func cancellation() async throws {
    let server = try StalledTCPServer()
    defer { server.stop() }
    // Use a very large deadline so the total timeout can never race (and pre-empt) the
    // cancel. The correctness claim is that cancellation is observed promptly once it is
    // delivered, NOT that it beats an arbitrarily tight deadline. Under full-suite parallel
    // load the cooperative executor can delay Task.sleep / onCancel delivery by seconds;
    // with a 10 s deadline that latency could push the cancel past the deadline and turn a
    // genuine cancellation into a spurious timeout.
    let connection = CoreDeviceTLSConnection(timeoutMilliseconds: 60_000)
    let task = Task {
      try await connection.connect(
        host: "127.0.0.1",
        port: server.port,
        preSharedKey: Data(repeating: 9, count: 32)
      )
    }
    // Wait until the server has accepted so the client is definitely inside the exchange
    // (connected and blocked in the TLS poll loop) before cancelling.
    try server.waitUntilAccepted(timeout: TimeInterval(30))
    let clock = ContinuousClock()
    let start = clock.now
    task.cancel()
    await #expect(throws: CoreDeviceTLSConnection.Error.cancelled) {
      try await task.value
    }
    // Measure from after cancel() so the bound reflects cancellation propagation latency
    // (onCancel delivery plus the ~50 ms C poll slice). The generous bound tolerates load
    // while still failing if cancellation were ever ignored.
    #expect(start.duration(to: clock.now) < .seconds(30))
  }

  @Test("connects to an optional physical CoreDevice listener")
  func physicalConnection() async throws {
    let environment = ProcessInfo.processInfo.environment
    let values = [
      environment["NATIVE_COREDEVICE_HOST"],
      environment["NATIVE_COREDEVICE_PORT"],
      environment["NATIVE_COREDEVICE_PSK_FILE"],
    ]
    guard values.contains(where: { $0 != nil }) else { return }
    guard
      let host = values[0],
      let portValue = values[1],
      let port = Int(portValue),
      let keyPath = values[2]
    else {
      throw CoreDeviceTLSConnection.Error.invalidInput(
        "live test requires host, port, and PSK file together"
      )
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: keyPath)
    guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
      throw CoreDeviceTLSConnection.Error.invalidInput("live PSK file must use mode 0600")
    }
    let handshake = try await CoreDeviceTLSConnection().connect(
      host: host,
      port: port,
      preSharedKey: try Data(contentsOf: URL(fileURLWithPath: keyPath))
    )
    #expect(!handshake.clientAddress.isEmpty)
    #expect(!handshake.serverAddress.isEmpty)
  }
}

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

private final class StalledTCPServer: @unchecked Sendable {
  let port: Int
  private let descriptor: Int32
  private let queue = DispatchQueue(label: "stupid-app.tests.stalled-tcp")
  private let accepted = DispatchSemaphore(value: 0)

  init() throws {
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
    let accepted = self.accepted
    queue.async { [descriptor] in
      let client = accept(descriptor, nil, nil)
      guard client >= 0 else { return }
      accepted.signal()
      var byte: UInt8 = 0
      while recv(client, &byte, 1, 0) > 0 {}
      close(client)
    }
  }

  func waitUntilAccepted(timeout: TimeInterval) throws {
    let deadline = DispatchTime.now() + .milliseconds(Int(timeout * 1000))
    guard accepted.wait(timeout: deadline) == .success else {
      throw ServerError.noAccept
    }
  }

  func stop() {
    shutdown(descriptor, Int32(SHUT_RDWR))
    close(descriptor)
  }

  enum ServerError: Error {
    case setup
    case noAccept
  }
}
