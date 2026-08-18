import Crypto
import Foundation
import Testing

@testable import DeviceKit

struct RemotePairingTests {
  @Test("TLV8 components round-trip through encode and decode")
  func tlv8RoundTrip() {
    let components: [(RemotePairing.ComponentType, Data)] = [
      (.state, Data([0x01])),
      (.identifier, Data("host-1".utf8)),
      (.publicKey, Data(repeating: 0xAB, count: 32)),
    ]
    let encoded = RemotePairing.encodeTLV(components)
    let decoded = RemotePairing.decodeTLV(encoded)
    #expect(decoded[.state] == Data([0x01]))
    #expect(decoded[.identifier] == Data("host-1".utf8))
    #expect(decoded[.publicKey] == Data(repeating: 0xAB, count: 32))
  }

  @Test("decodeTLV concatenates repeated component types")
  func tlv8Concatenation() {
    // The reference splits large ENCRYPTED_DATA into two 255-byte components.
    let a = Data(repeating: 0x11, count: 255)
    let b = Data(repeating: 0x22, count: 10)
    let encoded = RemotePairing.encodeTLV([(.encryptedData, a), (.encryptedData, b)])
    let decoded = RemotePairing.decodeTLV(encoded)
    #expect(decoded[.encryptedData] == a + b)
  }

  @Test("generateHostID produces a deterministic uppercase UUIDv3")
  func hostID() {
    let first = RemotePairing.generateHostID(hostname: "test-host.local")
    let second = RemotePairing.generateHostID(hostname: "test-host.local")
    #expect(first == second)
    #expect(first == first.uppercased())
    #expect(first.count == 36)
    // Version nibble (index 14 in canonical form) must be 3.
    let versionIndex = first.index(first.startIndex, offsetBy: 14)
    #expect(first[versionIndex] == "3")
  }

  @Test("record loads the three keyed data fields from a binary plist")
  func recordLoad() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let record = RemotePairing.Record(
      publicKey: Data([0x01]), privateKey: Data([0x02]), remoteUnlockHostKey: "unlock-host-key")
    let plist = try PropertyListSerialization.data(
      fromPropertyList: [
        "public_key": record.publicKey,
        "private_key": record.privateKey,
        "remote_unlock_host_key": record.remoteUnlockHostKey,
      ] as [String: Any],
      format: .binary, options: 0)
    let url = directory.appendingPathComponent("remote_0000-0000-0000-0000.plist")
    try plist.write(to: url)

    let loaded = try RemotePairing.Record.load(from: url)
    #expect(loaded.publicKey == record.publicKey)
    #expect(loaded.privateKey == record.privateKey)
    #expect(loaded.remoteUnlockHostKey == record.remoteUnlockHostKey)
  }

  @Test("pairedIdentifiers parses remote record file names")
  func pairedIdentifiers() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try Data([0x01]).write(to: directory.appendingPathComponent("remote_AAA.plist"))
    try Data([0x01]).write(to: directory.appendingPathComponent("remote_BBB.plist"))
    try Data([0x01]).write(to: directory.appendingPathComponent("other.plist"))

    let identifiers = try RemotePairing.pairedIdentifiers(in: directory)
    #expect(Set(identifiers) == Set(["AAA", "BBB"]))
  }

  @Test("pair-verify ChaCha20-Poly1305 wire format round-trips without the nonce")
  func chachaRoundTrip() throws {
    let key = Data(repeating: 0x5A, count: 32)
    let nonce = RemotePairingTunnelClient.Channel.sequenceNonce(0)
    let plaintext = Data("payload".utf8)
    let wire = try RemotePairingTunnelClient.Channel.encrypt(
      key: key, nonce: nonce, plaintext: plaintext)
    // 7 plaintext bytes + 16-byte tag, no nonce prefix.
    #expect(wire.count == 7 + 16)
    let opened = try RemotePairingTunnelClient.Channel.decrypt(
      key: key, nonce: nonce, ciphertext: wire)
    #expect(opened == plaintext)
  }

  @Test("sequence nonce is little-endian counter plus four zero bytes")
  func sequenceNonce() {
    let nonce = RemotePairingTunnelClient.Channel.sequenceNonce(1)
    let counter = nonce.prefix(8)
    #expect(Array(counter) == [1, 0, 0, 0, 0, 0, 0, 0])
    #expect(Array(nonce.suffix(4)) == [0, 0, 0, 0])
    #expect(nonce.count == 12)
  }

  @Test("client and server keys derived with the reference HKDF labels")
  func sessionKeys() throws {
    let encryptionKey = Data(repeating: 0x42, count: 32)
    let keys = RemotePairingTunnelClient.Channel.clientServerKeys(from: encryptionKey)
    #expect(keys.client.count == 32)
    #expect(keys.server.count == 32)
    #expect(keys.client != keys.server)
  }

  @Test("advertising addresses sort link-local IPv4 first")
  func addressSorting() {
    let v6 = RemotepairingDiscovery.Address(ip: "2001:db8::1", interface: nil)
    let v4Private = RemotepairingDiscovery.Address(ip: "192.168.1.5", interface: nil)
    #expect(v4Private < v6)
    #expect(v6.scopedIP == v6.ip)
    let linkLocal = RemotepairingDiscovery.Address(ip: "fe80::1", interface: "en0")
    #expect(linkLocal.scopedIP == "fe80::1%en0")
  }
}
