import CTUN
import Foundation
import Testing

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Hermetic tests for the TUN relay framing contract. The relay helpers must
/// round-trip complete IPv6 packets through a real descriptor: on Linux the
/// framing is the raw packet, while on macOS the utun protocol-family header is
/// prepended on write and stripped on read. The observable contract is identical
/// on both platforms, so a socket pair exercises it without a TUN device.
struct TUNRelayFramingTests {
  @Test("relay write followed by relay read round-trips a packet")
  func relayRoundTrip() throws {
    let pair = try socketPair()
    defer {
      close(pair.0)
      close(pair.1)
    }

    var packet = Data(repeating: 0, count: 40)
    packet[0] = 0x60  // IPv6 version 6
    packet[4] = 0x00  // payload length
    packet[5] = 0x20  // 32 bytes of payload
    packet.append(Data(repeating: 0xab, count: 32))

    let writeResult = packet.withUnsafeBytes {
      stupid_app_tun_relay_write(pair.0, $0.bindMemory(to: UInt8.self).baseAddress, packet.count)
    }
    #expect(writeResult == 0)

    var buffer = [UInt8](repeating: 0, count: 4096)
    let capacity = buffer.count
    let readResult = buffer.withUnsafeMutableBytes {
      stupid_app_tun_relay_read(pair.1, $0.bindMemory(to: UInt8.self).baseAddress, capacity)
    }
    #expect(readResult == packet.count)
    #expect(Data(buffer.prefix(Int(readResult))) == packet)
  }

  @Test("relay read reports a non-IPv6 protocol family as an error on macOS")
  func relayReadRejectsWrongFamily() throws {
    let pair = try socketPair()
    defer {
      close(pair.0)
      close(pair.1)
    }

    #if canImport(Darwin)
      // A utun packet always carries a 4-byte big-endian family header. A
      // non-IPv6 family must fail loudly rather than being forwarded raw.
      var nonIPv6 = Data([0x00, 0x00, 0x00, 0x02])  // AF_INET
      nonIPv6.append(Data(repeating: 0x00, count: 40))
      _ = Darwin.send(pair.0, [UInt8](nonIPv6), nonIPv6.count, 0)
      var buffer = [UInt8](repeating: 0, count: 4096)
      let capacity = buffer.count
      let readResult = buffer.withUnsafeMutableBytes {
        stupid_app_tun_relay_read(pair.1, $0.bindMemory(to: UInt8.self).baseAddress, capacity)
      }
      #expect(readResult < 0)
    #else
      // On Linux the relay is a raw passthrough; nothing to reject.
      #expect(true)
    #endif
  }

  private func socketPair() throws -> (Int32, Int32) {
    var descriptors: [Int32] = [0, 0]
    #if os(Linux)
      let result = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors)
    #else
      let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors)
    #endif
    guard result == 0 else {
      throw TUNTestError.socketPairFailed(errno)
    }
    return (descriptors[0], descriptors[1])
  }
}

private enum TUNTestError: Error {
  case socketPairFailed(Int32)
}
