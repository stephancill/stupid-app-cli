import Foundation

/// Pairs a device that has no USB trust path, such as an Apple TV, over the local
/// network. The device advertises `_remotepairing-manual-pairing._tcp` while its pairing
/// screen is open (Settings > Remotes and Devices > Remote App and Devices) and shows a
/// PIN once Pair-Setup starts. The exchange is the CoreDevice Pair-Setup used for USB
/// pairing, carried in RPPairing JSON frames instead of RemoteXPC. The resulting record
/// is stored like a USB-created one, so `run --network` uses it unchanged.
public struct NetworkManualPairer: Sendable {
  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidResponse(String)
    case recordWriteFailed(String)

    public var description: String {
      switch self {
      case .invalidResponse(let detail):
        return "The device's pairing response is invalid: \(detail)."
      case .recordWriteFailed(let detail):
        return "The remote pairing record could not be stored: \(detail)."
      }
    }
  }

  /// What the device reported about itself during the handshake.
  public struct PeerInfo: Sendable, Equatable {
    public var identifier: String
    public var name: String?
    public var model: String?
    public var udid: String?
  }

  public var host: String
  public var port: UInt16
  /// The advertised `identifier` TXT value; an unpaired Apple TV leaves the handshake's
  /// identifier empty, so the advertisement names the record instead.
  public var advertisedIdentifier: String?
  public var pairingDirectory: URL
  public var timeoutSeconds: Double
  public var progress: (@Sendable (String) -> Void)?

  public init(
    host: String, port: UInt16, advertisedIdentifier: String? = nil, pairingDirectory: URL,
    timeoutSeconds: Double = 120,
    progress: (@Sendable (String) -> Void)? = nil
  ) {
    self.host = host
    self.port = port
    self.advertisedIdentifier = advertisedIdentifier
    self.pairingDirectory = pairingDirectory
    self.timeoutSeconds = timeoutSeconds
    self.progress = progress
  }

  /// Pairs the device and stores the record. `pinProvider` is called once the device
  /// shows its PIN. Returns the device's handshake info; its `identifier` names the
  /// stored record.
  public func pair(pinProvider: () throws -> String) throws -> PeerInfo {
    let socket = try SocketConnection(
      address: "\(host):\(port)", timeoutSeconds: timeoutSeconds)
    defer { socket.closeImmediately() }
    let transport: CoreDeviceRemotePairing.Transport = { envelope, waitsForResponse in
      if let envelope {
        try Self.writeFrame(
          Self.jsonObject(.dictionary(envelope)) as! [String: Any], to: socket)
      }
      guard waitsForResponse else { return nil }
      return Self.xpcDictionary(try Self.readFrame(from: socket))
    }

    let peer = try handshake(transport: transport)
    progress?("Connected to \(peer.name ?? "the device") (\(peer.model ?? "unknown model")).")

    let hostname = ProcessInfo.processInfo.hostName
    let hostIdentifier = RemotePairing.generateHostID(hostname: hostname)
    let pairing = CoreDeviceRemotePairing()
    let validation = try pairing.validatePairing(
      transport: transport, identifier: hostIdentifier,
      recordPrivateKey: existingPrivateKey(identifier: peer.identifier),
      initialSequenceNumber: 1)
    if validation.alreadyPaired {
      progress?("The device already recognizes this host; no Pair-Setup is needed.")
    } else {
      let record = try pairing.pair(
        transport: transport, identifier: hostIdentifier, hostname: hostname,
        pinProvider: pinProvider, initialSequenceNumber: validation.nextSequenceNumber,
        requiresRemoteUnlock: false)
      try persist(record, identifier: peer.identifier)
      progress?("Stored the remote pairing record.")
    }
    if let udid = peer.udid {
      try RemotePairing.saveUdidMapping(
        identifier: peer.identifier, udid: udid, in: pairingDirectory)
    }
    return peer
  }

  /// Reads the UDID of a paired device: verifies the saved record against the device's
  /// `_remotepairing._tcp` listener at `host`, opens the CoreDevice tunnel, and reads
  /// the RSD peer info. An unpaired Apple TV does not share its UDID in the pairing
  /// handshake, so this runs once pairing completes, then stores the UDID mapping.
  public func resolveUDID(identifier: String, discoveryTimeout: Double = 5) throws -> String {
    let record = try RemotePairing.Record.load(
      from: RemotePairing.recordURL(identifier: identifier, in: pairingDirectory))
    var failures: [String] = []
    for attempt in 0..<6 {
      if attempt > 0 { Thread.sleep(forTimeInterval: 2) }
      let advertisements = try RemotepairingDiscovery().browse(timeout: discoveryTimeout)
      for advertisement in advertisements {
        guard let port = advertisement.port,
          advertisement.addresses.contains(where: { $0.ip == host })
        else { continue }
        do {
          let outcome = try RemotePairingTunnelClient(
            host: host, port: UInt16(port), timeoutSeconds: 15
          ).establish(record: record)
          let tunnel = try UserspaceCoreDeviceTunnel(
            host: host, port: Int(outcome.listenPort), preSharedKey: outcome.preSharedKey,
            timeoutSeconds: 30)
          defer { tunnel.closeTunnel() }
          let session = try tunnel.rsd(timeoutSeconds: 30).open()
          let udid = session.peerInfo.udid
          try RemotePairing.saveUdidMapping(
            identifier: identifier, udid: udid, in: pairingDirectory)
          return udid
        } catch {
          failures.append(String(describing: error))
        }
      }
    }
    throw Error.invalidResponse(
      "could not read the paired device's UDID over the tunnel"
        + (failures.isEmpty ? " (no paired listener advertised at \(host))" : ": \(failures.suffix(3).joined(separator: "; "))"))
  }

  private func handshake(transport: CoreDeviceRemotePairing.Transport) throws -> PeerInfo {
    let request: [String: XPCValue] = [
      "request": .dictionary([
        "_0": .dictionary([
          "handshake": .dictionary([
            "_0": .dictionary([
              "hostOptions": .dictionary(["attemptPairVerify": .bool(true)]),
              "wireProtocolVersion": .int64(RemotePairing.wireProtocolVersion),
            ])
          ])
        ])
      ])
    ]
    let envelope: [String: XPCValue] = [
      "message": .dictionary(["plain": .dictionary(["_0": .dictionary(request)])]),
      "originatedBy": .string("host"),
      "sequenceNumber": .uint64(0),
    ]
    guard let response = try transport(envelope, true) else {
      throw Error.invalidResponse("no handshake response")
    }
    if ProcessInfo.processInfo.environment["STUPID_APP_DEBUG_PAIRING"] != nil {
      progress?("Handshake response: \(response)")
    }
    guard
      let plain = response["message"]?.dictionaryValue?["plain"]?.dictionaryValue?["_0"]?
        .dictionaryValue,
      let info = plain["response"]?.dictionaryValue?["_1"]?.dictionaryValue?["handshake"]?
        .dictionaryValue?["_0"]?.dictionaryValue,
      let device = info["peerDeviceInfo"]?.dictionaryValue
    else {
      throw Error.invalidResponse("handshake omitted peerDeviceInfo")
    }
    let reported = device["identifier"]?.stringValue ?? ""
    let identifier = reported.isEmpty ? (advertisedIdentifier ?? "") : reported
    guard !identifier.isEmpty, !identifier.contains("/"), !identifier.contains("..") else {
      throw Error.invalidResponse(
        "neither the handshake nor the advertisement named the device identifier")
    }
    let udid = device["udid"]?.stringValue
    return PeerInfo(
      identifier: identifier,
      name: device["name"]?.stringValue,
      model: device["model"]?.stringValue,
      udid: udid?.isEmpty == false ? udid : nil)
  }

  private func existingPrivateKey(identifier: String) -> Data? {
    let url = RemotePairing.recordURL(identifier: identifier, in: pairingDirectory)
    return (try? RemotePairing.Record.load(from: url))?.privateKey
  }

  private func persist(_ record: CoreDeviceRemotePairing.SavedRecord, identifier: String) throws {
    do {
      let data = try record.plistData()
      try FileManager.default.createDirectory(
        at: pairingDirectory, withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: pairingDirectory.path)
      let destination = RemotePairing.recordURL(identifier: identifier, in: pairingDirectory)
      try data.write(to: destination, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: destination.path)
    } catch {
      throw Error.recordWriteFailed(String(describing: error))
    }
  }

  // MARK: - RPPairing framing

  /// `RPPairing` magic, a big-endian 16-bit length, then a JSON body.
  static func writeFrame(_ object: [String: Any], to connection: SocketConnection) throws {
    let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard body.count <= 65_535 else {
      throw RemotePairing.Error.invalidInput("request exceeds 64 KiB")
    }
    var frame = RemotePairing.magic
    frame.append(UInt8(body.count >> 8))
    frame.append(UInt8(body.count & 0xFF))
    frame.append(body)
    try connection.write(frame)
  }

  static func readFrame(from connection: SocketConnection) throws -> [String: Any] {
    guard try connection.read(count: RemotePairing.magic.count) == RemotePairing.magic else {
      throw RemotePairing.Error.invalidResponse("missing RPPairing magic")
    }
    let lengthBytes = try connection.read(count: 2)
    let length = Int(lengthBytes[0]) << 8 | Int(lengthBytes[1])
    let body = length > 0 ? try connection.read(count: length) : Data()
    guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      throw RemotePairing.Error.invalidResponse("RPPairing body is not a dictionary")
    }
    return object
  }

  // MARK: - JSON bridging

  /// RPPairing JSON carries binary values as base64 strings.
  static func jsonObject(_ value: XPCValue) -> Any {
    switch value {
    case .null: return NSNull()
    case .bool(let bool): return bool
    case .int64(let int): return int
    case .uint64(let uint): return uint
    case .double(let double): return double
    case .data(let data): return data.base64EncodedString()
    case .string(let string): return string
    case .uuid(let uuid): return uuid.uuidString
    case .array(let array): return array.map(jsonObject)
    case .dictionary(let dictionary): return dictionary.mapValues(jsonObject)
    }
  }

  /// Converts a received frame to XPC values. Pairing `data` payloads and encrypted
  /// stream bodies are base64 in JSON and become `.data`, as the shared Pair-Setup code
  /// reads them.
  static func xpcDictionary(_ object: [String: Any], parentKey: String? = nil)
    -> [String: XPCValue]
  {
    object.reduce(into: [:]) { result, entry in
      result[entry.key] = xpcValue(entry.value, key: entry.key, parentKey: parentKey)
    }
  }

  private static func xpcValue(_ value: Any, key: String, parentKey: String?) -> XPCValue {
    switch value {
    case let dictionary as [String: Any]:
      return .dictionary(xpcDictionary(dictionary, parentKey: key))
    case let array as [Any]:
      return .array(array.map { xpcValue($0, key: key, parentKey: parentKey) })
    case let string as String:
      let isBinary = key == "data" || (key == "_0" && parentKey == "streamEncrypted")
      if isBinary, let data = Data(base64Encoded: string) {
        return .data(data)
      }
      return .string(string)
    case let number as NSNumber:
      switch String(cString: number.objCType) {
      case "c", "B": return .bool(number.boolValue)
      case "f", "d": return .double(number.doubleValue)
      default: break
      }
      return .int64(number.int64Value)
    default:
      return .null
    }
  }
}
