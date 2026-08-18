import Crypto
import Foundation
import Testing

@testable import DeviceKit

/// Exercises the full `CoreDeviceRemotePairing` exchange against a scripted
/// server that mirrors the device's SRP-3072 and Pair-Verify side, proving the
/// verifyManualPairing validation, the Pair-Setup envelope sequence, the SRP
/// proof, the encrypted record handoff, and the remote-unlock request without
/// any physical device.
struct CoreDeviceRemotePairingTests {
  @Test("fresh device runs Pair-Verify rejection then Pair-Setup with immediate consent")
  func immediateConsent() throws {
    let server = FakePairingServer(mode: .immediate, paired: false)
    let pairing = CoreDeviceRemotePairing()
    let transport: CoreDeviceRemotePairing.Transport = { outgoing, waits in
      try server.respond(to: outgoing, waitsForResponse: waits)
    }

    let validation = try pairing.validatePairing(
      transport: transport,
      identifier: "HOST-00000000-0000-0000-0000-000000000001",
      recordPrivateKey: nil
    )
    #expect(!validation.alreadyPaired)
    #expect(validation.nextSequenceNumber == 2)

    let record = try pairing.pair(
      transport: transport,
      identifier: "HOST-00000000-0000-0000-0000-000000000001",
      hostname: "test-host.local",
      initialSequenceNumber: validation.nextSequenceNumber
    )
    #expect(record.publicKey.count == 32)
    #expect(record.privateKey.count == 32)
    #expect(record.remoteUnlockHostKey == "HOST-REMOTE-UNLOCK-KEY")
    #expect(server.receivedSendOnlyCalls == 1)
    #expect(
      server.receivedKinds
        == [
          "verifyManualPairing", "setupManualPairing", "setupManualPairing",
          "setupManualPairing", "streamEncrypted",
        ])
  }

  @Test("Pair-Setup completes when the device pushes pairing data after the Trust dialog")
  func awaitingConsentPush() throws {
    let server = FakePairingServer(mode: .awaitingConsent, paired: false)
    let pairing = CoreDeviceRemotePairing()
    let transport: CoreDeviceRemotePairing.Transport = { outgoing, waits in
      try server.respond(to: outgoing, waitsForResponse: waits)
    }

    let validation = try pairing.validatePairing(
      transport: transport,
      identifier: "HOST-00000000-0000-0000-0000-000000000002",
      recordPrivateKey: nil
    )
    let record = try pairing.pair(
      transport: transport,
      identifier: "HOST-00000000-0000-0000-0000-000000000002",
      hostname: "test-host.local",
      initialSequenceNumber: validation.nextSequenceNumber
    )

    #expect(record.publicKey.count == 32)
    #expect(record.privateKey.count == 32)
    #expect(record.remoteUnlockHostKey == "HOST-REMOTE-UNLOCK-KEY")
    // One extra receive-only read carries the pushed consent data.
    #expect(server.receivedReceiveOnlyCalls == 1)
  }

  @Test("a device that rejects the client proof fails loudly")
  func proofRejected() throws {
    let server = FakePairingServer(mode: .immediate, paired: false)
    server.rejectProof = true
    let pairing = CoreDeviceRemotePairing()
    let transport: CoreDeviceRemotePairing.Transport = { outgoing, waits in
      try server.respond(to: outgoing, waitsForResponse: waits)
    }

    let validation = try pairing.validatePairing(
      transport: transport,
      identifier: "HOST-00000000-0000-0000-0000-000000000003",
      recordPrivateKey: nil
    )
    #expect(throws: CoreDeviceRemotePairing.Error.self) {
      _ = try pairing.pair(
        transport: transport,
        identifier: "HOST-00000000-0000-0000-0000-000000000003",
        hostname: "test-host.local",
        initialSequenceNumber: validation.nextSequenceNumber
      )
    }
  }

  @Test("an already-paired device validates and skips Pair-Setup")
  func alreadyPaired() throws {
    let server = FakePairingServer(mode: .immediate, paired: true)
    let pairing = CoreDeviceRemotePairing()
    let transport: CoreDeviceRemotePairing.Transport = { outgoing, waits in
      try server.respond(to: outgoing, waitsForResponse: waits)
    }

    let validation = try pairing.validatePairing(
      transport: transport,
      identifier: "HOST-00000000-0000-0000-0000-000000000004",
      recordPrivateKey: Data(repeating: 0x11, count: 32)
    )
    #expect(validation.alreadyPaired)
    // Start (seq 0) and finish (seq 1); no send-only pairVerifyFailed.
    #expect(validation.nextSequenceNumber == 2)
    #expect(server.receivedSendOnlyCalls == 0)
    #expect(server.receivedKinds == ["verifyManualPairing", "verifyManualPairing"])
  }
}

private enum FakePairingServerError: Swift.Error {
  case malformed
  case unexpectedState
  case proofMismatch
  case missingState
}

/// A scripted SRP-3072 server that speaks the CoreDevice tunnel-service
/// envelope framing. It mirrors `srptools`/pymobiledevice3 server math so the
/// client's proof and encrypted record handoff validate. `paired` controls the
/// verifyManualPairing result: a paired device accepts the validation, an
/// unpaired device returns an error and expects a send-only pairVerifyFailed.
private final class FakePairingServer: @unchecked Sendable {
  enum Mode {
    case immediate
    case awaitingConsent
  }

  let mode: Mode
  let paired: Bool
  var rejectProof = false
  private(set) var receivedKinds: [String] = []
  private(set) var receivedReceiveOnlyCalls = 0
  private(set) var receivedSendOnlyCalls = 0

  private let pin = "000000"
  private let username = "Pair-Setup"
  private let salt = Data([
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
    0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
    0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
    0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10,
  ])
  private let privateB: BigUInt
  private let verifier: BigUInt
  private let serverPublic: BigUInt

  private var keyBytes: Data?
  private var setupKey: Data?
  private var clientKey: Data?
  private var serverKey: Data?

  init(mode: Mode, paired: Bool) {
    self.mode = mode
    self.paired = paired
    let n = SRPClient.prime
    let g = SRPClient.generator
    let paddedLength = n.data.count
    let k = SRPClient.hashInt([
      .data(n.data),
      .data(g.paddedData(to: paddedLength)),
    ])
    let inner = SRPClient.digest(
      [.string(username), .string(pin)], joiner: Data(":".utf8))
    let x = SRPClient.hashInt([.data(salt), .data(inner)])
    let verifier = g.power(x, mod: n)
    privateB = BigUInt(
      data: Data([
        0x5A, 0x5A, 0x5A, 0x5A, 0x5A, 0x5A, 0x5A, 0x5A,
        0x5A, 0x5A, 0x5A, 0x5A, 0x5A, 0x5A, 0x5A, 0x5A,
        0x5A, 0x5A, 0x5A, 0x5A, 0x5A, 0x5A, 0x5A, 0x5A,
        0x5A, 0x5A, 0x5A, 0x5A, 0x5A, 0x5A, 0x5A, 0x5A,
      ]))
    let bPublic = g.power(privateB, mod: n)
    serverPublic = (k * verifier + bPublic) % n
    self.verifier = verifier
  }

  func respond(to envelope: [String: XPCValue]?, waitsForResponse: Bool) throws
    -> [String: XPCValue]?
  {
    if !waitsForResponse {
      receivedSendOnlyCalls += 1
      return nil
    }
    guard let envelope else {
      receivedReceiveOnlyCalls += 1
      return try consentDataResponse()
    }

    if let stream = envelope["message"]?.dictionaryValue?["streamEncrypted"]?.dictionaryValue {
      receivedKinds.append("streamEncrypted")
      return try remoteUnlockResponse(stream)
    }

    guard
      let plain = envelope["message"]?.dictionaryValue?["plain"]?.dictionaryValue,
      let inner = plain["_0"]?.dictionaryValue
    else {
      throw FakePairingServerError.malformed
    }
    let kind =
      inner["event"]?.dictionaryValue?["_0"]?.dictionaryValue?["pairingData"]?.dictionaryValue?[
        "_0"
      ]?.dictionaryValue?["kind"]?.stringValue
    receivedKinds.append(kind ?? "plain")
    let data = try pairingDataBytes(inner)
    let components = RemotePairing.decodeTLV(data)

    if kind == "verifyManualPairing" {
      switch components[.state]?.first {
      case 0x01:
        return paired ? try verifyStartResponse() : verifyErrorResponse()
      case 0x03:
        return paired ? verifyFinishResponse() : verifyErrorResponse()
      default:
        throw FakePairingServerError.unexpectedState
      }
    }

    switch components[.state]?.first {
    case 0x01:
      if mode == .awaitingConsent {
        return plainResponse(
          inner: [
            "event": .dictionary([
              "_0": .dictionary(["awaitingUserConsent": .dictionary([:])])
            ])
          ])
      }
      return try consentDataResponse()
    case 0x03:
      return try proofResponse(components)
    case 0x05:
      return try saveOnPeerResponse(components)
    default:
      throw FakePairingServerError.unexpectedState
    }
  }

  private func verifyStartResponse() throws -> [String: XPCValue] {
    pairingDataResponse(
      data: splitTLV([
        (.state, Data([0x01])),
        // A decodable X25519 public key (top bit clear).
        (.publicKey, Data(repeating: 0x2A, count: 32)),
      ]))
  }

  private func verifyFinishResponse() -> [String: XPCValue] {
    pairingDataResponse(
      data: splitTLV([
        (.state, Data([0x03]))
      ]))
  }

  private func verifyErrorResponse() -> [String: XPCValue] {
    pairingDataResponse(
      data: splitTLV([
        (.state, Data([0x01])),
        (.error, Data([0x01])),
      ]))
  }

  private func pairingDataBytes(_ inner: [String: XPCValue]) throws -> Data {
    guard
      let event = inner["event"]?.dictionaryValue,
      let e0 = event["_0"]?.dictionaryValue,
      let pairing = e0["pairingData"]?.dictionaryValue,
      let p0 = pairing["_0"]?.dictionaryValue,
      let data = p0["data"]?.dataValue
    else {
      throw FakePairingServerError.malformed
    }
    return data
  }

  private func consentDataResponse() throws -> [String: XPCValue] {
    pairingDataResponse(
      data: splitTLV([
        (.publicKey, serverPublic.data),
        (.salt, salt),
      ]))
  }

  private func proofResponse(_ components: [RemotePairing.ComponentType: Data]) throws
    -> [String: XPCValue]
  {
    guard
      let publicBytes = components[.publicKey],
      let clientProof = components[.proof]
    else {
      throw FakePairingServerError.malformed
    }
    let n = SRPClient.prime
    let g = SRPClient.generator
    let paddedLength = n.data.count
    let aPublic = BigUInt(data: publicBytes)

    let u = SRPClient.hashInt([
      .data(aPublic.paddedData(to: paddedLength)),
      .data(serverPublic.paddedData(to: paddedLength)),
    ])
    let base = (aPublic * verifier.power(u, mod: n)) % n
    let shared = base.power(privateB, mod: n)
    let derivedKey = SRPClient.sha512(shared.data)

    let hN = SRPClient.sha512(n.data)
    let hG = SRPClient.sha512(g.data)
    let hU = SRPClient.digest([.string(username)])
    let hNXorHG = BigUInt(data: Data(zip(hN, hG).map { $0 ^ $1 }))
    let expectedM = SRPClient.digest([
      .int(hNXorHG),
      .int(BigUInt(data: hU)),
      .data(salt),
      .int(aPublic),
      .int(serverPublic),
      .data(derivedKey),
    ])
    guard expectedM == clientProof else {
      throw FakePairingServerError.proofMismatch
    }
    let serverProof = SRPClient.digest([.int(aPublic), .data(expectedM), .data(derivedKey)])

    keyBytes = derivedKey
    setupKey = try CoreDeviceRemotePairing.Client.hkdf(
      key: derivedKey,
      salt: Data("Pair-Setup-Encrypt-Salt".utf8),
      info: Data("Pair-Setup-Encrypt-Info".utf8))
    let keys = RemotePairingTunnelClient.Channel.clientServerKeys(from: derivedKey)
    clientKey = keys.client
    serverKey = keys.server

    return pairingDataResponse(
      data: splitTLV([
        (.state, Data([0x03])),
        (.proof, rejectProof ? Data([0x00]) : serverProof),
      ]))
  }

  private func saveOnPeerResponse(_ components: [RemotePairing.ComponentType: Data]) throws
    -> [String: XPCValue]
  {
    guard
      let encrypted = components[.encryptedData],
      let setupKey
    else {
      throw FakePairingServerError.malformed
    }
    let peerTLV = try CoreDeviceRemotePairing.Client.decrypt(
      key: setupKey,
      nonce: Data([0, 0, 0, 0]) + Data("PS-Msg05".utf8),
      ciphertext: encrypted)
    let responseEncrypted = try CoreDeviceRemotePairing.Client.encrypt(
      key: setupKey,
      nonce: Data([0, 0, 0, 0]) + Data("PS-Msg06".utf8),
      plaintext: peerTLV)
    return pairingDataResponse(
      data: splitTLV([
        (.state, Data([0x05])),
        (.encryptedData, responseEncrypted),
      ]))
  }

  private func remoteUnlockResponse(_ stream: [String: XPCValue]) throws -> [String: XPCValue] {
    guard
      let encrypted = stream["_0"]?.dataValue,
      let clientKey,
      let serverKey
    else {
      throw FakePairingServerError.malformed
    }
    let nonce = RemotePairingTunnelClient.Channel.sequenceNonce(0)
    let plaintext = try CoreDeviceRemotePairing.Client.decrypt(
      key: clientKey, nonce: nonce, ciphertext: encrypted)
    _ = plaintext
    let response: [String: Any] = [
      "response": [
        "_1": [
          "createRemoteUnlockKey": [
            "hostKey": "HOST-REMOTE-UNLOCK-KEY"
          ]
        ]
      ]
    ]
    let body = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    let encryptedResponse = try CoreDeviceRemotePairing.Client.encrypt(
      key: serverKey, nonce: nonce, plaintext: body)
    return [
      "message": .dictionary(["streamEncrypted": .dictionary(["_0": .data(encryptedResponse)])])
    ]
  }

  private func pairingDataResponse(data: Data) -> [String: XPCValue] {
    let inner: [String: XPCValue] = [
      "event": .dictionary([
        "_0": .dictionary([
          "pairingData": .dictionary([
            "_0": .dictionary(["data": .data(data)])
          ])
        ])
      ])
    ]
    return plainResponse(inner: inner)
  }

  private func plainResponse(inner: [String: XPCValue]) -> [String: XPCValue] {
    ["message": .dictionary(["plain": .dictionary(["_0": .dictionary(inner)])])]
  }

  /// Encodes TLV8 components, splitting any value longer than 255 bytes into
  /// repeated components because the wire length prefix is one byte.
  private func splitTLV(_ components: [(RemotePairing.ComponentType, Data)]) -> Data {
    var out = Data()
    for (type, data) in components {
      if data.count <= 255 {
        out.append(RemotePairing.encodeTLV([(type, data)]))
      } else {
        let chunks = stride(from: 0, to: data.count, by: 255).map {
          data.subdata(in: $0..<min($0 + 255, data.count))
        }
        out.append(RemotePairing.encodeTLV(chunks.map { (type, $0) }))
      }
    }
    return out
  }
}
