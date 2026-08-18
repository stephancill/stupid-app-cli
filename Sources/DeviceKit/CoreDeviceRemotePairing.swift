import Crypto
import Foundation

/// Runs the CoreDevice Pair-Setup exchange to create a remote pairing record
/// over the RSD `com.apple.internal.dt.coredevice.untrusted.tunnelservice`
/// connection, replacing the Python `pair-usb` helper. It reuses the validated
/// SRP-3072 client, ChaCha20-Poly1305/HKDF helpers, and the TLV8/OPACK codecs.
public struct CoreDeviceRemotePairing: Sendable {
  public struct SavedRecord: Sendable {
    public var publicKey: Data
    public var privateKey: Data
    public var remoteUnlockHostKey: String

    public func plistData() throws -> Data {
      try PropertyListSerialization.data(
        fromPropertyList: [
          "public_key": publicKey,
          "private_key": privateKey,
          "remote_unlock_host_key": remoteUnlockHostKey,
        ] as [String: Any],
        format: .binary,
        options: 0)
    }
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidResponse(String)
    case transport(String)
    case phase(String, String)

    public var description: String {
      switch self {
      case .invalidResponse(let detail):
        return "The CoreDevice pairing response is invalid: \(detail)."
      case .transport(let detail):
        return "The CoreDevice pairing exchange failed: \(detail)."
      case .phase(let phase, let detail):
        return "CoreDevice Pair-Setup \(phase) failed: \(detail)."
      }
    }
  }

  /// `transport(outgoing, waitsForResponse)` frames the outgoing envelope and
  /// returns the device's response envelope (its `value` dictionary). A `nil`
  /// envelope performs a receive-only read (the device pushes awaiting-consent
  /// data); `waitsForResponse == false` sends without reading a reply, matching
  /// the device's fire-and-forget `pairVerifyFailed` event. The caller owns the
  /// mangled-Type-Name wrapper.
  public typealias Transport =
    @Sendable ([String: XPCValue]?, Bool) throws
    -> [String: XPCValue]?

  public struct ValidationResult: Sendable, Equatable {
    public var alreadyPaired: Bool
    public var nextSequenceNumber: Int64
  }

  public func pair(
    transport: @escaping Transport,
    identifier: String,
    hostname: String,
    pin: String = "000000",
    initialSequenceNumber: Int64 = 0
  ) throws -> SavedRecord {
    var session = Session(transport: transport, sequenceNumber: initialSequenceNumber)
    let serverValues = try session.requestConsent(hostname: hostname)
    var client = try session.srpClient(
      serverPublic: serverValues.serverPublic, salt: serverValues.salt, pin: pin)
    client.sequenceNumber = max(client.sequenceNumber, session.sequenceNumber)
    try client.verifyProof()
    try client.saveRecordOnPeer(identifier: identifier, hostname: hostname)
    client.initSessionKeys()
    let remoteUnlock = try client.createRemoteUnlock()
    return SavedRecord(
      publicKey: client.ed25519PublicKey,
      privateKey: client.ed25519PrivateKey,
      remoteUnlockHostKey: remoteUnlock)
  }

  /// Runs the Pair-Verify validation exchange the device requires before it
  /// accepts Pair-Setup. When the device already recognizes this host (an
  /// existing record validates), `alreadyPaired` is true and Pair-Setup must be
  /// skipped; otherwise the device returns an error and the caller proceeds to
  /// `pair()` from the returned sequence number.
  public func validatePairing(
    transport: @escaping Transport,
    identifier: String,
    recordPrivateKey: Data?,
    initialSequenceNumber: Int64 = 0
  ) throws -> ValidationResult {
    var session = Session(transport: transport, sequenceNumber: initialSequenceNumber)
    let x25519 = Curve25519.KeyAgreement.PrivateKey()
    let x25519Public = x25519.publicKey.rawRepresentation

    let startTLV = RemotePairing.encodeTLV([
      (.state, Data([0x01])),
      (.publicKey, x25519Public),
    ])
    let startResponse = try session.sendPlain(
      eventData: startTLV, kind: "verifyManualPairing", sendingHost: nil, startNewSession: true)
    let startComponents = RemotePairing.decodeTLV(try Session.pairingDataBytes(startResponse))
    if startComponents[.error] != nil {
      try session.sendPairVerifyFailed()
      return ValidationResult(alreadyPaired: false, nextSequenceNumber: session.sequenceNumber)
    }
    guard let peerPublicKey = startComponents[.publicKey], peerPublicKey.count == 32 else {
      throw Error.invalidResponse("the device omitted its X25519 public key")
    }

    let sharedSecret = try x25519.sharedSecretFromKeyAgreement(
      with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey))
    let exchange = sharedSecret.withUnsafeBytes { Data($0) }
    let derivedKey = try Client.hkdf(
      key: exchange,
      salt: Data("Pair-Verify-Encrypt-Salt".utf8),
      info: Data("Pair-Verify-Encrypt-Info".utf8))

    var signBuffer = Data()
    signBuffer.append(x25519Public)
    signBuffer.append(Data(identifier.utf8))
    signBuffer.append(peerPublicKey)
    let signingKey = recordPrivateKey ?? Data(repeating: 0, count: 32)
    let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: signingKey)
    let signature = try signer.signature(for: signBuffer)

    let encryptedInner = RemotePairing.encodeTLV([
      (.identifier, Data(identifier.utf8)),
      (.signature, signature),
    ])
    let encryptedData = try Client.encrypt(
      key: derivedKey,
      nonce: Data([0, 0, 0, 0]) + Data("PV-Msg03".utf8),
      plaintext: encryptedInner)
    let finishTLV = RemotePairing.encodeTLV([
      (.state, Data([0x03])),
      (.encryptedData, encryptedData),
    ])
    let finishResponse = try session.sendPlain(
      eventData: finishTLV, kind: "verifyManualPairing", sendingHost: nil, startNewSession: false)
    let finishComponents = RemotePairing.decodeTLV(try Session.pairingDataBytes(finishResponse))
    if finishComponents[.error] != nil {
      try session.sendPairVerifyFailed()
      return ValidationResult(alreadyPaired: false, nextSequenceNumber: session.sequenceNumber)
    }
    return ValidationResult(alreadyPaired: true, nextSequenceNumber: session.sequenceNumber)
  }

  struct Session: Sendable {
    let transport: Transport
    var sequenceNumber: Int64

    init(transport: @escaping Transport, sequenceNumber: Int64 = 0) {
      self.transport = transport
      self.sequenceNumber = sequenceNumber
    }

    mutating func requestConsent(hostname: String) throws -> (serverPublic: Data, salt: Data) {
      let tlv = RemotePairing.encodeTLV([
        (.method, Data([0x00])),
        (.state, Data([0x01])),
      ])
      let response = try sendPlain(
        eventData: tlv, kind: "setupManualPairing", sendingHost: hostname, startNewSession: true)
      let isAwaitingConsent =
        response["event"]?.dictionaryValue?["_0"]?.dictionaryValue?["awaitingUserConsent"] != nil
      let responseData: Data
      if isAwaitingConsent {
        // The device pushes the pairing data once the user approves the Trust dialog.
        let pushed = try receivePlain()
        responseData = try Self.pairingDataBytes(pushed)
      } else {
        responseData = try Self.pairingDataBytes(response)
      }
      let components = RemotePairing.decodeTLV(responseData)
      guard let serverPublic = components[.publicKey], let salt = components[.salt] else {
        throw Error.invalidResponse("consent omitted the server public key and salt")
      }
      return (serverPublic, salt)
    }

    mutating func srpClient(serverPublic: Data, salt: Data, pin: String) throws -> Client {
      var randomBytes = [UInt8](repeating: 0, count: 128)
      for index in randomBytes.indices {
        randomBytes[index] = UInt8.random(in: 0...255)
      }
      let privateA = BigUInt(data: Data(randomBytes))
      return try Client(
        transport: transport,
        sequenceNumber: sequenceNumber,
        serverPublic: serverPublic,
        salt: salt,
        pin: pin,
        privateA: privateA)
    }

    mutating func sendPlain(
      eventData: Data, kind: String, sendingHost: String?, startNewSession: Bool
    ) throws -> [String: XPCValue] {
      let inner = Self.event(
        containing: eventData, kind: kind, sendingHost: sendingHost,
        startNewSession: startNewSession)
      let envelope: [String: XPCValue] = [
        "message": .dictionary(["plain": .dictionary(["_0": .dictionary(inner)])]),
        "originatedBy": .string("host"),
        "sequenceNumber": .uint64(UInt64(bitPattern: sequenceNumber)),
      ]
      sequenceNumber += 1
      guard let response = try transport(envelope, true) else {
        throw Error.transport("the pairing exchange omitted a response")
      }
      return Self.responsePlain(response)
    }

    mutating func receivePlain() throws -> [String: XPCValue] {
      guard let response = try transport(nil, true) else {
        throw Error.transport("the device did not push the expected message")
      }
      return Self.responsePlain(response)
    }

    mutating func sendPairVerifyFailed() throws {
      let inner: [String: XPCValue] = [
        "event": .dictionary(["_0": .dictionary(["pairVerifyFailed": .dictionary([:])])])
      ]
      let envelope: [String: XPCValue] = [
        "message": .dictionary(["plain": .dictionary(["_0": .dictionary(inner)])]),
        "originatedBy": .string("host"),
        "sequenceNumber": .uint64(UInt64(bitPattern: sequenceNumber)),
      ]
      sequenceNumber += 1
      _ = try transport(envelope, false)
    }

    static func event(
      containing data: Data, kind: String, sendingHost: String?, startNewSession: Bool
    ) -> [String: XPCValue] {
      var node: [String: XPCValue] = [
        "kind": .string(kind),
        "data": .data(data),
        "startNewSession": .bool(startNewSession),
      ]
      if let sendingHost {
        node["sendingHost"] = .string(sendingHost)
      }
      return [
        "event": .dictionary([
          "_0": .dictionary(["pairingData": .dictionary(["_0": .dictionary(node)])])
        ])
      ]
    }

    static func responsePlain(_ response: [String: XPCValue]) -> [String: XPCValue] {
      response["message"]?.dictionaryValue?["plain"]?.dictionaryValue?["_0"]?.dictionaryValue
        ?? [:]
    }

    static func pairingDataBytes(_ response: [String: XPCValue]) throws -> Data {
      guard
        let event = response["event"]?.dictionaryValue,
        let e0 = event["_0"]?.dictionaryValue,
        let pairingData = e0["pairingData"]?.dictionaryValue,
        let p0 = pairingData["_0"]?.dictionaryValue,
        let data = p0["data"]?.dataValue
      else {
        throw Error.invalidResponse("pairing response omitted pairing data")
      }
      return data
    }
  }

  struct Client: Sendable {
    let transport: Transport
    var sequenceNumber: Int64
    var encryptedSequenceNumber: Int64 = 0
    let salt: Data
    let serverPublic: Data
    let encryptionKey: Data
    let aPublic: Data
    let keyProof: Data
    let keyProofHash: Data
    var clientKey = Data()
    var serverKey = Data()
    var ed25519PrivateKey = Data()
    var ed25519PublicKey = Data()

    init(
      transport: @escaping Transport, sequenceNumber: Int64, serverPublic: Data, salt: Data,
      pin: String, privateA: BigUInt
    ) throws {
      self.transport = transport
      self.sequenceNumber = sequenceNumber
      self.serverPublic = serverPublic
      self.salt = salt
      let client = SRPClient(username: "Pair-Setup", password: pin, privateA: privateA)
      let s = try client.process(salt: salt, serverPublic: BigUInt(data: serverPublic))
      encryptionKey = s.sessionKey
      aPublic = client.clientPublic.data
      keyProof = s.keyProof
      keyProofHash = s.keyProofHash
    }

    mutating func verifyProof() throws {
      var tlv = RemotePairing.encodeTLV([(.state, Data([0x03]))])
      tlv.append(RemotePairing.encodeTLV([(.publicKey, Data(aPublic.prefix(255)))]))
      tlv.append(RemotePairing.encodeTLV([(.publicKey, Data(aPublic.dropFirst(255)))]))
      tlv.append(RemotePairing.encodeTLV([(.proof, keyProof)]))
      let response = try sendPlain(
        eventData: tlv, kind: "setupManualPairing", sendingHost: nil, startNewSession: false)
      let responseData = try Session.pairingDataBytes(response)
      guard let serverProof = RemotePairing.decodeTLV(responseData)[.proof] else {
        throw Error.invalidResponse("proof response omitted the server proof")
      }
      guard serverProof == keyProofHash else {
        throw Error.transport("the server proof did not match")
      }
    }

    mutating func saveRecordOnPeer(identifier: String, hostname: String) throws {
      let setupKey = try Self.hkdf(
        key: encryptionKey, salt: Data("Pair-Setup-Encrypt-Salt".utf8),
        info: Data("Pair-Setup-Encrypt-Info".utf8))
      var privateBytes = [UInt8](repeating: 0, count: 32)
      for index in privateBytes.indices {
        privateBytes[index] = UInt8.random(in: 0...255)
      }
      ed25519PrivateKey = Data(privateBytes)
      let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: ed25519PrivateKey)
      ed25519PublicKey = signer.publicKey.rawRepresentation

      let signMaterial = try Self.hkdf(
        key: encryptionKey, salt: Data("Pair-Setup-Controller-Sign-Salt".utf8),
        info: Data("Pair-Setup-Controller-Sign-Info".utf8))
      var signBuffer = Data()
      signBuffer.append(signMaterial)
      signBuffer.append(Data(identifier.utf8))
      signBuffer.append(ed25519PublicKey)
      let signature = try signer.signature(for: signBuffer)

      let deviceInfo = OPack.encodeDictionary([
        OPackEntry(
          key: .string("altIRK"),
          value: .data(
            Data([
              0xE9, 0xE8, 0x2D, 0xC0, 0x6A, 0x49, 0x79, 0x6B, 0x56, 0x6F, 0x54, 0x00, 0x19, 0xB1,
              0xC7, 0x7B,
            ]))),
        OPackEntry(key: .string("btAddr"), value: .string("11:22:33:44:55:66")),
        OPackEntry(key: .string("mac"), value: .data(Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66]))),
        OPackEntry(key: .string("remotepairing_serial_number"), value: .string("AAAAAAAAAAAA")),
        OPackEntry(key: .string("accountID"), value: .string(identifier)),
        OPackEntry(key: .string("model"), value: .string("computer-model")),
        OPackEntry(key: .string("name"), value: .string(hostname)),
      ])

      let peerTLV = RemotePairing.encodeTLV([
        (.identifier, Data(identifier.utf8)),
        (.publicKey, ed25519PublicKey),
        (.signature, signature),
        (.info, deviceInfo),
      ])
      let encrypted = try Self.encrypt(
        key: setupKey, nonce: Data([0, 0, 0, 0]) + Data("PS-Msg05".utf8), plaintext: peerTLV)

      var out = RemotePairing.encodeTLV([(.state, Data([0x05]))])
      out.append(RemotePairing.encodeTLV([(.encryptedData, Data(encrypted.prefix(255)))]))
      out.append(RemotePairing.encodeTLV([(.encryptedData, Data(encrypted.dropFirst(255)))]))
      let response = try sendPlain(
        eventData: out, kind: "setupManualPairing", sendingHost: nil, startNewSession: false)
      let responseData = try Session.pairingDataBytes(response)
      guard let peerEncrypted = RemotePairing.decodeTLV(responseData)[.encryptedData] else {
        throw Error.invalidResponse("record handoff omitted encrypted data")
      }
      _ = try Self.decrypt(
        key: setupKey, nonce: Data([0, 0, 0, 0]) + Data("PS-Msg06".utf8), ciphertext: peerEncrypted)
    }

    mutating func initSessionKeys() {
      let keys = RemotePairingTunnelClient.Channel.clientServerKeys(from: encryptionKey)
      clientKey = keys.client
      serverKey = keys.server
    }

    mutating func createRemoteUnlock() throws -> String {
      let request: [String: Any] = [
        "request": ["_0": ["createRemoteUnlockKey": [:] as [String: Any]]]
      ]
      let nonce = RemotePairingTunnelClient.Channel.sequenceNonce(encryptedSequenceNumber)
      let body = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
      let encrypted = try Self.encrypt(key: clientKey, nonce: nonce, plaintext: body)
      let envelope: [String: XPCValue] = [
        "message": .dictionary(["streamEncrypted": .dictionary(["_0": .data(encrypted)])]),
        "originatedBy": .string("host"),
        "sequenceNumber": .uint64(UInt64(bitPattern: sequenceNumber)),
      ]
      let response = try transport(envelope, true)
      encryptedSequenceNumber += 1
      guard let response else {
        throw Error.transport("the encrypted exchange omitted a response")
      }
      guard
        let stream = response["message"]?.dictionaryValue?["streamEncrypted"]?.dictionaryValue,
        let encryptedData = stream["_0"]?.dataValue
      else {
        throw Error.invalidResponse("encrypted response is malformed")
      }
      let plaintext = try Self.decrypt(key: serverKey, nonce: nonce, ciphertext: encryptedData)
      guard
        let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
        let top = object["response"] as? [String: Any],
        let result = top["_1"] as? [String: Any],
        let listener = result["createRemoteUnlockKey"] as? [String: Any],
        let hostKey = listener["hostKey"] as? String
      else {
        throw Error.invalidResponse("createRemoteUnlockKey omitted hostKey")
      }
      return hostKey
    }

    mutating func sendPlain(
      eventData: Data, kind: String, sendingHost: String?, startNewSession: Bool
    ) throws -> [String: XPCValue] {
      let inner = Session.event(
        containing: eventData, kind: kind, sendingHost: sendingHost,
        startNewSession: startNewSession)
      let envelope: [String: XPCValue] = [
        "message": .dictionary(["plain": .dictionary(["_0": .dictionary(inner)])]),
        "originatedBy": .string("host"),
        "sequenceNumber": .uint64(UInt64(bitPattern: sequenceNumber)),
      ]
      sequenceNumber += 1
      guard let response = try transport(envelope, true) else {
        throw Error.transport("the pairing exchange omitted a response")
      }
      return Session.responsePlain(response)
    }

    static func hkdf(key: Data, salt: Data, info: Data) throws -> Data {
      let derived = HKDF<SHA512>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: key),
        salt: salt,
        info: info,
        outputByteCount: 32)
      return derived.withUnsafeBytes { Data($0) }
    }

    static func encrypt(key: Data, nonce: Data, plaintext: Data) throws -> Data {
      let nonceValue = try ChaChaPoly.Nonce(data: nonce)
      let box = try ChaChaPoly.seal(
        plaintext, using: SymmetricKey(data: key), nonce: nonceValue, authenticating: Data())
      return Data(box.combined.dropFirst(12))
    }

    static func decrypt(key: Data, nonce: Data, ciphertext: Data) throws -> Data {
      let box = try ChaChaPoly.SealedBox(combined: nonce + ciphertext)
      return try ChaChaPoly.open(box, using: SymmetricKey(data: key))
    }
  }
}
