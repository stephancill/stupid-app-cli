import CCoreDeviceTLS
import CUserspaceIP
import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Process-local IPv6/TCP stack with no kernel interfaces or routes.
/// The pinned lwIP raw API permits one active instance per process.
final class UserspaceIPStack: @unchecked Sendable {
  private let handle: OpaquePointer
  private let lock = NSLock()
  private var stopped = false

  init(packetDescriptor: Int32, client: String, server: String, mtu: UInt16 = 1500) throws {
    var output: OpaquePointer?
    let result = stupid_app_userspace_ip_create(packetDescriptor, client, server, mtu, &output)
    guard result == 0, let output else {
      throw USBMuxClient.Error.invalidInput("userspace stack creation failed (code \(result))")
    }
    handle = output
  }

  func connect(port: Int, timeoutSeconds: Double) throws -> SocketConnection {
    guard (1...65_535).contains(port), timeoutSeconds > 0, timeoutSeconds.isFinite,
      timeoutSeconds * 1_000 <= Double(Int32.max)
    else { throw USBMuxClient.Error.invalidInput("invalid userspace endpoint or timeout") }
    let descriptor = stupid_app_userspace_ip_connect(
      handle, UInt16(port), Int32(timeoutSeconds * 1_000))
    guard descriptor >= 0 else { throw USBMuxClient.Error.connectionFailed(-descriptor) }
    return try SocketConnection(adopting: descriptor, timeoutSeconds: timeoutSeconds)
  }

  func stop() {
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else { return }
    stopped = true
    stupid_app_userspace_ip_stop(handle)
  }

  deinit {
    stop()
    stupid_app_userspace_ip_destroy(handle)
  }
}

final class UserspaceCoreDeviceTunnel: @unchecked Sendable {
  private let handle: OpaquePointer
  private let packetDescriptor: Int32
  private let stack: UserspaceIPStack
  private let queue = DispatchQueue(label: "stupid-app.userspace-tls")
  private let stopFlag: UnsafeMutablePointer<Int32>
  private let lock = NSLock()
  private var closed = false
  let handshake: CoreDeviceTLSConnection.Handshake

  init(host: String, port: Int, preSharedKey: Data, timeoutSeconds: Double) throws {
    guard (1...65_535).contains(port), !preSharedKey.isEmpty, preSharedKey.count <= 256,
      timeoutSeconds > 0, timeoutSeconds.isFinite,
      timeoutSeconds * 1_000 <= Double(Int32.max)
    else { throw PersistentCoreDeviceTunnel.Error.invalidInput("invalid userspace TLS parameters") }
    var output: OpaquePointer?
    var response = Data(count: 10 + 16_384)
    let capacity = response.count
    var length = 0
    let result = preSharedKey.withUnsafeBytes { key in
      response.withUnsafeMutableBytes { buffer in
        stupid_app_coredevice_tls_tunnel_connect(
          host, UInt16(port), key.bindMemory(to: UInt8.self).baseAddress, preSharedKey.count,
          Int32(timeoutSeconds * 1_000), buffer.bindMemory(to: UInt8.self).baseAddress,
          capacity, &length, &output)
      }
    }
    guard result == 0, let output else { throw PersistentCoreDeviceTunnel.Error.connect(result) }
    var descriptors = [Int32](repeating: -1, count: 2)
    var completed = false
    defer {
      if !completed {
        for descriptor in descriptors where descriptor >= 0 { _ = close(descriptor) }
        stupid_app_coredevice_tls_tunnel_destroy(output)
      }
    }
    response.removeSubrange(length..<response.count)
    let decoded = try CoreDeviceTLSConnection.decode(response)
    #if os(Linux)
      let type = Int32(SOCK_DGRAM.rawValue)
    #else
      let type = SOCK_DGRAM
    #endif
    guard socketpair(AF_UNIX, type, 0, &descriptors) == 0 else {
      throw USBMuxClient.Error.connectionFailed(errno)
    }
    for descriptor in descriptors {
      var size: Int32 = 1024 * 1024
      _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
      _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }
    let userspace = try UserspaceIPStack(
      packetDescriptor: descriptors[0], client: decoded.clientAddress,
      server: decoded.serverAddress,
      mtu: UInt16(min(decoded.clientMTU, 1500)))
    descriptors[0] = -1  // Ownership moved into the stack.
    stack = userspace
    packetDescriptor = descriptors[1]
    handshake = decoded
    handle = output
    stopFlag = .allocate(capacity: 1)
    stopFlag.initialize(to: 0)
    completed = true
    let handleBits = UInt(bitPattern: output)
    let flagBits = UInt(bitPattern: stopFlag)
    let packetFD = packetDescriptor
    // No strong self capture: deinit must be able to cancel and join this work.
    queue.async {
      _ = stupid_app_coredevice_tls_tunnel_relay_packets(
        OpaquePointer(bitPattern: handleBits), packetFD,
        UnsafeMutablePointer<Int32>(bitPattern: flagBits))
      _ = shutdown(packetFD, Int32(SHUT_RDWR))
    }
  }

  func rsd(timeoutSeconds: Double) -> RSDClient {
    let server = handshake.serverAddress
    return RSDClient(
      host: server, port: handshake.serverRSDPort, timeoutSeconds: timeoutSeconds,
      dial: { [stack] host, port, timeout in
        guard host == server else { throw USBMuxClient.Error.invalidAddress }
        return try stack.connect(port: port, timeoutSeconds: timeout)
      })
  }

  func closeTunnel() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    lock.unlock()
    stupid_app_coredevice_tls_tunnel_cancel(handle)
    _ = shutdown(packetDescriptor, Int32(SHUT_RDWR))
    queue.sync {}
    stack.stop()
  }

  deinit {
    closeTunnel()
    stupid_app_coredevice_tls_tunnel_destroy(handle)
    _ = close(packetDescriptor)
    stopFlag.deallocate()
  }
}
