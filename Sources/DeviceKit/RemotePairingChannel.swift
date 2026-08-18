import Crypto
import Foundation

/// Establishes a CoreDevice network tunnel listener from a saved remote
/// pairing record. It performs the RPPairing Pair-Verify exchange over the
/// advertised listener, derives the session keys, and asks the device to open
/// a TCP tunnel. The returned key is the PSK for the persistent TLS tunnel.
public struct RemotePairingTunnelClient: Sendable {
  public var host: String
  public var port: UInt16
  public var timeoutSeconds: Double

  public init(host: String, port: UInt16, timeoutSeconds: Double = 15) {
    self.host = host
    self.port = port
    self.timeoutSeconds = timeoutSeconds
  }

  public struct Outcome: Equatable, Sendable {
    public var listenPort: UInt16
    public var preSharedKey: Data
  }

  /// Connects to the advertised listener with the given record and returns the
  /// TCP listener port and the PSK for the persistent tunnel.
  public func establish(record: RemotePairing.Record) throws -> Outcome {
    guard timeoutSeconds > 0 else {
      throw RemotePairing.Error.invalidInput("timeout must be positive")
    }
    let socket = try SocketConnection(
      address: "\(host):\(port)",
      timeoutSeconds: timeoutSeconds
    )
    var channel = try Channel(connection: socket, timeoutSeconds: timeoutSeconds)
    do {
      try channel.handshake()
      try channel.pairVerify(record: record)
      channel.initSessionKeys()
      let listener = try channel.createTCPListener()
      return Outcome(listenPort: listener, preSharedKey: channel.encryptionKey)
    } catch {
      socket.closeImmediately()
      throw error
    }
  }

  /// Holds the RPPairing state machine over one established socket.
  struct Channel {
    let connection: SocketConnection
    let timeoutSeconds: Double
    let x25519PrivateKey = Curve25519.KeyAgreement.PrivateKey()
    var identifier: String
    var sequenceNumber: Int64 = 0
    var encryptedSequenceNumber: Int64 = 0
    var encryptionKey = Data()
    var clientKey = Data()
    var serverKey = Data()

    init(connection: SocketConnection, timeoutSeconds: Double) {
      self.connection = connection
      self.timeoutSeconds = timeoutSeconds
      self.identifier = RemotePairing.generateHostID(
        hostname: ProcessInfo.processInfo.hostName)
    }

    var x25519PublicKey: Data {
      x25519PrivateKey.publicKey.rawRepresentation
    }

    // MARK: Exchange

    func readFrame() throws -> [String: Any] {
      let magic = try connection.read(count: RemotePairing.magic.count)
      guard magic == RemotePairing.magic else {
        throw RemotePairing.Error.invalidResponse("missing RPPairing magic")
      }
      let lengthBytes = try connection.read(count: 2)
      let length = Int(lengthBytes[0]) << 8 | Int(lengthBytes[1])
      guard (0...65_536).contains(length) else {
        throw RemotePairing.Error.invalidResponse("invalid RPPairing frame length")
      }
      let body = length > 0 ? try connection.read(count: length) : Data()
      guard
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
      else {
        throw RemotePairing.Error.invalidResponse("RPPairing body is not a dictionary")
      }
      return object
    }

    func writeFrame(_ object: [String: Any]) throws {
      let body: Data
      do {
        body = try JSONSerialization.data(
          withJSONObject: object, options: [.sortedKeys])
      } catch {
        throw RemotePairing.Error.invalidInput("could not serialize the request")
      }
      guard body.count <= 65_536 else {
        throw RemotePairing.Error.invalidInput("request exceeds 64 KiB")
      }
      var frame = RemotePairing.magic
      frame.append(UInt8(body.count >> 8))
      frame.append(UInt8(body.count & 0xFF))
      frame.append(body)
      try connection.write(frame)
    }

    private func sendEnvelope(message: [String: Any]) throws {
      try writeFrame([
        "message": message,
        "originatedBy": "host",
        "sequenceNumber": sequenceNumber,
      ])
    }

    private func receiveEnvelope() throws -> (message: [String: Any], value: [String: Any]) {
      let envelope = try readFrame()
      guard let message = envelope["message"] as? [String: Any] else {
        throw RemotePairing.Error.invalidResponse("envelope omits message")
      }
      return (message, envelope)
    }

    mutating func sendPlain(_ inner: [String: Any]) throws {
      try sendEnvelope(message: ["plain": ["_0": inner]])
      sequenceNumber += 1
    }

    func receivePlain() throws -> [String: Any] {
      let (message, _) = try receiveEnvelope()
      guard
        let plain = message["plain"] as? [String: Any],
        let inner = plain["_0"] as? [String: Any]
      else {
        throw RemotePairing.Error.invalidResponse("response omits plain payload")
      }
      return inner
    }

    mutating func sendReceive(from dictionary: [String: Any]) throws -> [String: Any] {
      try sendPlain(dictionary)
      return try receivePlain()
    }

    // MARK: Handshake

    mutating func handshake() throws {
      let request: [String: Any] = [
        "request": [
          "_0": [
            "handshake": [
              "_0": [
                "hostOptions": ["attemptPairVerify": true],
                "wireProtocolVersion": RemotePairing.wireProtocolVersion,
              ]
            ]
          ]
        ]
      ]
      let response = try sendReceive(from: request)
      guard
        let top = response["response"] as? [String: Any],
        let one = top["_1"] as? [String: Any],
        let handshake = one["handshake"] as? [String: Any],
        let info = handshake["_0"] as? [String: Any],
        !info.isEmpty
      else {
        throw RemotePairing.Error.invalidResponse("handshake response is malformed")
      }
    }

    // MARK: Pair-Verify

    mutating func pairVerify(record: RemotePairing.Record) throws {
      let verifyStart: [String: Any] = [
        "event": [
          "_0": [
            "pairingData": [
              "_0": [
                "kind": "verifyManualPairing",
                "data": base64(
                  RemotePairing.encodeTLV([
                    (.state, Data([0x01])),
                    (.publicKey, x25519PublicKey),
                  ])),
                "startNewSession": true,
              ]
            ]
          ]
        ]
      ]
      let responseData = try pairingData(from: sendReceive(from: verifyStart))
      let components = RemotePairing.decodeTLV(responseData)
      guard let peerPublicKey = components[.publicKey], peerPublicKey.count == 32 else {
        throw RemotePairing.Error.invalidResponse("peer omitted its X25519 public key")
      }

      let sharedSecret = try x25519PrivateKey.sharedSecretFromKeyAgreement(
        with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey))
      let exchange = sharedSecret.withUnsafeBytes { Data($0) }
      let derivedKey = try Self.hkdf(
        key: exchange,
        salt: Data("Pair-Verify-Encrypt-Salt".utf8),
        info: Data("Pair-Verify-Encrypt-Info".utf8))

      var signBuffer = Data()
      signBuffer.append(x25519PublicKey)
      signBuffer.append(Data(identifier.utf8))
      signBuffer.append(peerPublicKey)

      let signingPrivateKey = record.privateKey
      let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: signingPrivateKey)
      let signature = try signer.signature(for: signBuffer)

      let encryptedInner = RemotePairing.encodeTLV([
        (.identifier, Data(identifier.utf8)),
        (.signature, signature),
      ])
      let encryptedData = try Self.encrypt(
        key: derivedKey,
        nonce: Data("PV-Msg03".utf8),
        plaintext: encryptedInner)

      let verifyFinish: [String: Any] = [
        "event": [
          "_0": [
            "pairingData": [
              "_0": [
                "kind": "verifyManualPairing",
                "data": base64(
                  RemotePairing.encodeTLV([
                    (.state, Data([0x03])),
                    (.encryptedData, encryptedData),
                  ])),
                "startNewSession": false,
              ]
            ]
          ]
        ]
      ]
      let finalData = try pairingData(from: sendReceive(from: verifyFinish))
      if RemotePairing.decodeTLV(finalData)[.error] != nil {
        throw RemotePairing.Error.pairing("the device rejected the Pair-Verify signature")
      }

      self.encryptionKey = exchange
    }

    private func pairingData(from plain: [String: Any]) throws -> Data {
      guard
        let event = plain["event"] as? [String: Any],
        let e0 = event["_0"] as? [String: Any],
        let pairingData = e0["pairingData"] as? [String: Any],
        let p0 = pairingData["_0"] as? [String: Any],
        let encoded = p0["data"] as? String,
        let data = Data(base64Encoded: encoded)
      else {
        throw RemotePairing.Error.invalidResponse("pairing data response is malformed")
      }
      return data
    }

    mutating func initSessionKeys() {
      let keys = Self.clientServerKeys(from: encryptionKey)
      clientKey = keys.client
      serverKey = keys.server
    }

    static func clientServerKeys(from encryptionKey: Data) -> (client: Data, server: Data) {
      let client =
        (try? Self.hkdf(
          key: encryptionKey, salt: Data(), info: Data("ClientEncrypt-main".utf8))) ?? Data()
      let server =
        (try? Self.hkdf(
          key: encryptionKey, salt: Data(), info: Data("ServerEncrypt-main".utf8))) ?? Data()
      return (client, server)
    }

    // MARK: Listener

    mutating func createTCPListener() throws -> UInt16 {
      let request: [String: Any] = [
        "request": [
          "_0": [
            "createListener": [
              "key": base64(encryptionKey),
              "peerConnectionsInfo": [
                [
                  "owningPID": Int(ProcessInfo.processInfo.processIdentifier),
                  "owningProcessName": "stupid-app",
                ]
              ],
              "transportProtocolType": "tcp",
            ]
          ]
        ]
      ]
      let response = try sendReceiveEncrypted(request)
      guard
        let listener = response["createListener"] as? [String: Any],
        let rawPort = listener["port"] as? UInt64,
        (1...65_535).contains(rawPort)
      else {
        throw RemotePairing.Error.invalidResponse("createListener omitted a valid port")
      }
      return UInt16(rawPort)
    }

    private mutating func sendReceiveEncrypted(_ request: [String: Any]) throws -> [String: Any] {
      let nonce = Self.sequenceNonce(encryptedSequenceNumber)
      let body: Data
      do {
        body = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
      } catch {
        throw RemotePairing.Error.invalidInput("could not serialize the encrypted request")
      }
      let encrypted = try Self.encrypt(key: clientKey, nonce: nonce, plaintext: body)

      try sendEnvelope(message: ["streamEncrypted": ["_0": base64(encrypted)]])
      encryptedSequenceNumber += 1
      // Encrypted sends do not increment the plain sequence number.

      let (message, _) = try receiveEnvelope()
      guard
        let stream = message["streamEncrypted"] as? [String: Any],
        let encoded = stream["_0"] as? String,
        let encryptedData = Data(base64Encoded: encoded)
      else {
        throw RemotePairing.Error.invalidResponse("encrypted response is malformed")
      }
      let plaintext = try Self.decrypt(key: serverKey, nonce: nonce, ciphertext: encryptedData)
      guard
        let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
        let top = object["response"] as? [String: Any],
        let result = top["_1"] as? [String: Any]
      else {
        throw RemotePairing.Error.invalidResponse("decrypted response is malformed")
      }
      return result
    }

    // MARK: Crypto helpers

    static func hkdf(key: Data, salt: Data, info: Data) throws -> Data {
      let derived = try HKDF<SHA512>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: key),
        salt: salt,
        info: info,
        outputByteCount: 32)
      return derived.withUnsafeBytes { Data($0) }
    }

    static func sequenceNonce(_ value: Int64) -> Data {
      var nonce = Data()
      var encoded = UInt64(bitPattern: value).littleEndian
      withUnsafeBytes(of: &encoded) { nonce.append(contentsOf: $0) }
      nonce.append(contentsOf: [0, 0, 0, 0])
      return nonce
    }

    static func encrypt(key: Data, nonce: Data, plaintext: Data) throws -> Data {
      guard nonce.count == 12 else {
        throw RemotePairing.Error.invalidInput("nonce must be 12 bytes")
      }
      let nonceValue = try ChaChaPoly.Nonce(data: nonce)
      let box = try ChaChaPoly.seal(
        plaintext, using: SymmetricKey(data: key), nonce: nonceValue, authenticating: Data())
      // The wire carries ciphertext + tag without the nonce.
      return Data(box.combined.dropFirst(12))
    }

    static func decrypt(key: Data, nonce: Data, ciphertext: Data) throws -> Data {
      guard nonce.count == 12 else {
        throw RemotePairing.Error.invalidInput("nonce must be 12 bytes")
      }
      let box = try ChaChaPoly.SealedBox(combined: nonce + ciphertext)
      return try ChaChaPoly.open(box, using: SymmetricKey(data: key))
    }

    func base64(_ data: Data) -> String {
      data.base64EncodedString()
    }
  }
}
