import Crypto
import Foundation
import Testing

@testable import DeviceKit

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct RemotePairingIdentityTests {
  @Test("Pair-Verify signs the original identity when a pairing is used on another host")
  func copiedPairingIdentity() async throws {
    var descriptors = [Int32](repeating: -1, count: 2)
    #if os(Linux)
      let type = Int32(SOCK_STREAM.rawValue)
    #else
      let type = SOCK_STREAM
    #endif
    #expect(socketpair(AF_UNIX, type, 0, &descriptors) == 0)
    let clientSocket = try SocketConnection(adopting: descriptors[0], timeoutSeconds: 10)
    let serverSocket = try SocketConnection(adopting: descriptors[1], timeoutSeconds: 10)
    defer {
      clientSocket.closeImmediately()
      serverSocket.closeImmediately()
    }
    let original = "00000000-0000-3000-8000-000000000001"
    let signingKey = Curve25519.Signing.PrivateKey()
    let publicKey = signingKey.publicKey.rawRepresentation
    // The client uses blocking socket I/O. Run the peer outside the cooperative
    // executor so a busy test suite cannot starve the matching socket reader.
    let (outcomes, continuation) = AsyncStream<Result<Void, any Error>>.makeStream()
    DispatchQueue.global().async {
      do {
        var server = RemotePairingTunnelClient.Channel(
          connection: serverSocket, timeoutSeconds: 10)
        let first = try server.receivePlain()
        let clientPublic = try #require(Self.components(first)[.publicKey])
        try server.sendPlain(
          Self.response([
            (.state, Data([2])), (.publicKey, server.x25519PublicKey),
          ]))
        let finish = try server.receivePlain()
        let encrypted = try #require(Self.components(finish)[.encryptedData])
        let shared = try server.x25519PrivateKey.sharedSecretFromKeyAgreement(
          with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPublic))
        let key = try RemotePairingTunnelClient.Channel.hkdf(
          key: shared.withUnsafeBytes { Data($0) },
          salt: Data("Pair-Verify-Encrypt-Salt".utf8),
          info: Data("Pair-Verify-Encrypt-Info".utf8))
        let inner = RemotePairing.decodeTLV(
          try RemotePairingTunnelClient.Channel.decrypt(
            key: key, nonce: Data([0, 0, 0, 0]) + Data("PV-Msg03".utf8), ciphertext: encrypted))
        #expect(inner[.identifier] == Data(original.utf8))
        let signature = try #require(inner[.signature])
        let message = clientPublic + Data(original.utf8) + server.x25519PublicKey
        #expect(
          try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            .isValidSignature(signature, for: message))
        try server.sendPlain(Self.response([(.state, Data([4]))]))
        continuation.yield(.success(()))
      } catch {
        continuation.yield(.failure(error))
      }
      continuation.finish()
    }
    var client = RemotePairingTunnelClient.Channel(
      connection: clientSocket, timeoutSeconds: 10, identifier: original)
    try client.pairVerify(
      record: RemotePairing.Record(
        publicKey: publicKey, privateKey: signingKey.rawRepresentation,
        remoteUnlockHostKey: "test-unlock"))
    for await outcome in outcomes { try outcome.get() }
  }

  private static func components(_ message: [String: Any]) throws -> [RemotePairing.ComponentType:
    Data]
  {
    let event = try #require(message["event"] as? [String: Any])
    let body = try #require(event["_0"] as? [String: Any])
    let pairing = try #require(body["pairingData"] as? [String: Any])
    let payload = try #require(pairing["_0"] as? [String: Any])
    let encoded = try #require(payload["data"] as? String)
    return RemotePairing.decodeTLV(try #require(Data(base64Encoded: encoded)))
  }

  private static func response(_ components: [(RemotePairing.ComponentType, Data)]) -> [String: Any]
  {
    [
      "event": [
        "_0": [
          "pairingData": [
            "_0": [
              "data": RemotePairing.encodeTLV(components).base64EncodedString()
            ]
          ]
        ]
      ]
    ]
  }
}
