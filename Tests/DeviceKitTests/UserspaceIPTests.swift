import CUserspaceIP
import Foundation
import Testing

@testable import DeviceKit

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

@Suite(.serialized)
struct UserspaceIPTests {
  @Test("lwIP connects concurrent IPv6 streams and round-trips a 12 MiB transfer")
  func largeTransfer() async throws {
    let peer = try UserspaceTCPPeer()
    let stack = try UserspaceIPStack(
      packetDescriptor: peer.takeStackDescriptor(), client: "fd00::1", server: "fd00::2")
    defer {
      stack.stop()
      peer.stop()
    }
    let control = try stack.connect(port: 6000, timeoutSeconds: 5)
    let data = try stack.connect(port: 6001, timeoutSeconds: 30)
    let chunk = Data((0..<32768).map { UInt8($0 & 255) })
    let writer = Task.detached {
      for _ in 0..<384 { try data.write(chunk) }
    }
    for _ in 0..<384 {
      #expect(try data.read(count: chunk.count) == chunk)
    }
    try await writer.value
    try control.write(Data("still alive".utf8))
    #expect(try control.read(count: 11) == Data("still alive".utf8))
    #expect(peer.maximumPacketLength <= 1500)
    control.closeImmediately()
    data.closeImmediately()
  }

  @Test("unanswered dial has a bounded timeout and can be cancelled")
  func timeoutAndCancellation() async throws {
    let peer = try UserspaceTCPPeer(answer: false)
    let stack = try UserspaceIPStack(
      packetDescriptor: peer.takeStackDescriptor(), client: "fd00::1", server: "fd00::2")
    defer {
      stack.stop()
      peer.stop()
    }
    let start = ContinuousClock.now
    #expect(throws: USBMuxClient.Error.connectionFailed(ETIMEDOUT)) {
      _ = try stack.connect(port: 6000, timeoutSeconds: 0.1)
    }
    #expect(ContinuousClock.now - start < .seconds(2))
    let dial = Task.detached {
      try stack.connect(port: 6001, timeoutSeconds: 30)
    }
    try await Task.sleep(for: .milliseconds(50))
    stack.stop()
    do {
      _ = try await dial.value
      Issue.record("A stopped tunnel must not connect")
    } catch {}
    #expect(ContinuousClock.now - start < .seconds(2))
    stack.stop()
  }

  @Test("lost TCP payload is retransmitted without losing stream bytes")
  func retransmission() throws {
    let peer = try UserspaceTCPPeer(dropFirstPayload: true)
    let stack = try UserspaceIPStack(
      packetDescriptor: peer.takeStackDescriptor(), client: "fd00::1", server: "fd00::2")
    defer {
      stack.stop()
      peer.stop()
    }
    let connection = try stack.connect(port: 6000, timeoutSeconds: 10)
    let data = Data("retransmit this".utf8)
    try connection.write(data)
    #expect(try connection.read(count: data.count) == data)
    connection.closeImmediately()
  }

  @Test("singleton guard fails explicitly and sequential teardown permits a new stack")
  func ownership() throws {
    for _ in 0..<3 {
      let peer = try UserspaceTCPPeer()
      do {
        let stack = try UserspaceIPStack(
          packetDescriptor: peer.takeStackDescriptor(), client: "fd00::1", server: "fd00::2")
        var handle: OpaquePointer?
        let descriptor = dup(peer.descriptor)
        defer { _ = close(descriptor) }
        #expect(
          stupid_app_userspace_ip_create(
            descriptor, "fd00::1", "fd00::2", 1500, &handle) == EBUSY)
        #expect(handle == nil)
        let connection = try stack.connect(port: 6000, timeoutSeconds: 5)
        try connection.write(Data("ok".utf8))
        #expect(try connection.read(count: 2) == Data("ok".utf8))
        connection.closeImmediately()
        stack.stop()
      }
      peer.stop()
    }
  }
}

/// A deterministic IPv6/TCP peer, independent of lwIP. It validates outgoing
/// checksums and implements SYN/ACK plus a byte echo; no host network interface.
private final class UserspaceTCPPeer: @unchecked Sendable {
  let descriptor: Int32
  private var stackDescriptor: Int32
  private let queue = DispatchQueue(label: "stupid-app.tests.userspace-peer")
  private let lock = NSLock()
  private var stopped = false
  private var maximumLength = 0
  private let answer: Bool
  private var dropFirstPayload: Bool
  private var connections: [UInt16: (clientNext: UInt32, peerNext: UInt32)] = [:]
  private var unacknowledged: [(local: UInt16, end: UInt32, packet: [UInt8])] = []
  private var lastRetransmission = ContinuousClock.now

  var maximumPacketLength: Int {
    lock.lock()
    defer { lock.unlock() }
    return maximumLength
  }

  init(answer: Bool = true, dropFirstPayload: Bool = false) throws {
    self.answer = answer
    self.dropFirstPayload = dropFirstPayload
    var pair = [Int32](repeating: -1, count: 2)
    #if os(Linux)
      let type = Int32(SOCK_DGRAM.rawValue)
    #else
      let type = SOCK_DGRAM
    #endif
    guard socketpair(AF_UNIX, type, 0, &pair) == 0 else {
      throw USBMuxClient.Error.connectionFailed(errno)
    }
    descriptor = pair[0]
    stackDescriptor = pair[1]
    for fd in pair {
      var size: Int32 = 1024 * 1024
      _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
      _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    }
    var timeout = timeval(tv_sec: 1, tv_usec: 0)
    _ = setsockopt(
      descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    // Explicit stop joins before releasing this instance.
    queue.async { [self] in serve() }
  }

  func takeStackDescriptor() -> Int32 {
    let descriptor = stackDescriptor
    stackDescriptor = -1
    return descriptor
  }

  func stop() {
    lock.lock()
    let alreadyStopped = stopped
    stopped = true
    lock.unlock()
    guard !alreadyStopped else { return }
    _ = shutdown(descriptor, Int32(SHUT_RDWR))
    queue.sync {}
  }

  deinit {
    _ = close(descriptor)
    if stackDescriptor >= 0 { _ = close(stackDescriptor) }
  }

  private func serve() {
    while true {
      lock.lock()
      let done = stopped
      lock.unlock()
      if done { return }
      if ContinuousClock.now - lastRetransmission > .milliseconds(200) {
        for pending in unacknowledged { sendPacket(pending.packet) }
        lastRetransmission = .now
      }
      var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      if poll(&pollDescriptor, 1, 50) <= 0 { continue }
      var bytes = [UInt8](repeating: 0, count: 65576)
      let count = recv(descriptor, &bytes, bytes.count, 0)
      guard count >= 60 else { continue }
      bytes.removeSubrange(count..<bytes.count)
      lock.lock()
      maximumLength = max(maximumLength, count)
      lock.unlock()
      guard bytes[6] == 6, answer else { continue }
      let tcp = Array(bytes[40...])
      let pseudo =
        Array(bytes[8..<40]) + [0, 0, UInt8(tcp.count >> 8), UInt8(tcp.count & 255), 0, 0, 0, 6]
      guard checksum(pseudo + tcp) == 0 else {
        Issue.record("lwIP emitted an invalid IPv6 TCP checksum")
        return
      }
      let localPort = uint16(bytes, 40)
      let remotePort = uint16(bytes, 42)
      let sequence = uint32(bytes, 44)
      let flags = bytes[53]
      if flags & 0x10 != 0 {
        let acknowledgment = uint32(bytes, 48)
        unacknowledged.removeAll { $0.local == localPort && $0.end <= acknowledgment }
      }
      if flags & 4 != 0 {
        connections.removeValue(forKey: localPort)
        unacknowledged.removeAll { $0.local == localPort }
        continue
      }
      if flags & 2 != 0 {
        let peerSequence: UInt32 = 100_000
        connections[localPort] = (sequence &+ 1, peerSequence &+ 1)
        reply(
          local: localPort, remote: remotePort, sequence: peerSequence,
          acknowledgment: sequence &+ 1, flags: 0x12, payload: [],
          options: [2, 4, 5, 160, 1, 3, 3, 3])
        continue
      }
      guard var state = connections[localPort] else { continue }
      let offset = 40 + Int(bytes[52] >> 4) * 4
      guard offset <= bytes.count else { continue }
      let payload = Array(bytes[offset...])
      if !payload.isEmpty {
        if dropFirstPayload {
          dropFirstPayload = false
          continue
        }
        if sequence == state.clientNext {
          state.clientNext &+= UInt32(payload.count)
          reply(
            local: localPort, remote: remotePort, sequence: state.peerNext,
            acknowledgment: state.clientNext, flags: 0x18, payload: payload)
          state.peerNext &+= UInt32(payload.count)
          connections[localPort] = state
        } else {
          reply(
            local: localPort, remote: remotePort, sequence: state.peerNext,
            acknowledgment: state.clientNext, flags: 0x10, payload: [])
        }
      }
    }
  }

  private func reply(
    local: UInt16, remote: UInt16, sequence: UInt32,
    acknowledgment: UInt32, flags: UInt8, payload: [UInt8], options: [UInt8] = []
  ) {
    let address = [UInt8]([0xfd, 0] + Array(repeating: 0, count: 13))
    let source = address + [2]
    let destination = address + [1]
    var tcp = encoded(remote) + encoded(local) + encoded(sequence) + encoded(acknowledgment)
    tcp += [UInt8((20 + options.count) / 4) << 4, flags, 255, 255, 0, 0, 0, 0]
    tcp += options + payload
    let length = tcp.count
    let pseudo = source + destination + [0, 0, UInt8(length >> 8), UInt8(length & 255), 0, 0, 0, 6]
    let sum = checksum(pseudo + tcp)
    tcp[16] = UInt8(sum >> 8)
    tcp[17] = UInt8(sum & 255)
    var packet: [UInt8] = [0x60, 0, 0, 0, UInt8(length >> 8), UInt8(length & 255), 6, 64]
    packet += source + destination + tcp
    if !payload.isEmpty {
      unacknowledged.append((local, sequence &+ UInt32(payload.count), packet))
    }
    sendPacket(packet)
  }

  private func sendPacket(_ packet: [UInt8]) {
    let result = send(descriptor, packet, packet.count, Int32(MSG_DONTWAIT))
    if result != packet.count && errno != EAGAIN && errno != EWOULDBLOCK && errno != ENOBUFS {
      Issue.record("Synthetic peer packet write failed (errno \(errno))")
    }
  }

  private func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
  }

  private func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(uint16(bytes, offset)) << 16 | UInt32(uint16(bytes, offset + 2))
  }

  private func encoded<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.bigEndian) { Array($0) }
  }

  private func checksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var cursor = 0
    while cursor + 1 < bytes.count {
      sum += UInt32(bytes[cursor]) << 8 | UInt32(bytes[cursor + 1])
      cursor += 2
    }
    if cursor < bytes.count { sum += UInt32(bytes[cursor]) << 8 }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return ~UInt16(sum)
  }
}
