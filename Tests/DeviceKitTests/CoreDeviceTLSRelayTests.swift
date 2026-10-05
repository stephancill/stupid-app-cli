import CCoreDeviceTLS
import CCoreDeviceTLSTestSupport
import Foundation
import Testing

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct CoreDeviceTLSRelayTests {
  @Test("TLS relay ignores stale errors from a previously used worker thread")
  func reusedWorkerErrorQueue() throws {
    var peer: OpaquePointer?
    var port: UInt16 = 0
    try #require(stupid_app_test_tls_peer_create(&port, &peer) == 0)
    defer { stupid_app_test_tls_peer_destroy(peer) }
    var tunnel: OpaquePointer?
    var response = Data(count: 1024)
    var length = 0
    let psk = Data(repeating: 7, count: 32)
    let connected = psk.withUnsafeBytes { key in
      response.withUnsafeMutableBytes { bytes in
        stupid_app_coredevice_tls_tunnel_connect(
          "127.0.0.1", port, key.bindMemory(to: UInt8.self).baseAddress, psk.count,
          5_000, bytes.bindMemory(to: UInt8.self).baseAddress, 1024, &length, &tunnel)
      }
    }
    try #require(connected == 0)
    defer { stupid_app_coredevice_tls_tunnel_destroy(tunnel) }
    var pair = [Int32](repeating: -1, count: 2)
    #if os(Linux)
      let type = Int32(SOCK_DGRAM.rawValue)
    #else
      let type = SOCK_DGRAM
    #endif
    try #require(socketpair(AF_UNIX, type, 0, &pair) == 0)
    defer { for descriptor in pair { _ = close(descriptor) } }
    var packet = Data(repeating: 0, count: 60)
    packet[0] = 0x60
    packet[5] = 20
    packet[6] = 6
    packet[7] = 64
    let sent = packet.withUnsafeBytes { send(pair[1], $0.baseAddress, packet.count, 0) }
    try #require(sent == packet.count)
    // Seed on the exact thread that invokes the relay; no scheduler reuse is
    // needed to reproduce the contaminated-worker failure deterministically.
    try #require(stupid_app_test_tls_seed_error() == 1)
    var stop: Int32 = 0
    let result = stupid_app_coredevice_tls_tunnel_relay_packets(tunnel, pair[0], &stop)
    try #require(result == 0)
    var receiveTimeout = timeval(tv_sec: 5, tv_usec: 0)
    try #require(
      setsockopt(
        pair[1], SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
        socklen_t(MemoryLayout<timeval>.size)) == 0)
    var echoed = Data(count: packet.count)
    let received = echoed.withUnsafeMutableBytes { recv(pair[1], $0.baseAddress, packet.count, 0) }
    #expect(received == packet.count)
    #expect(echoed == packet)
  }
}
