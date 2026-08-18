import Foundation

/// Native client for the RSD `com.apple.internal.dt.coredevice.untrusted.tunnelservice`
/// service. It performs the ServiceVersion handshake, the attemptPairVerify
/// handshake that reveals the device's remote-pairing identifier, and then
/// serves as the transport for `CoreDeviceRemotePairing`. Every exchange is
/// wrapped in the `RemotePairing.ControlChannelMessageEnvelope` mangled type
/// name, matching the pinned pymobiledevice3 reference.
public final class CoreDeviceTunnelService: @unchecked Sendable {
  public static let serviceName = "com.apple.internal.dt.coredevice.untrusted.tunnelservice"
  public static let wireProtocolVersion: Int64 = 19

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidServiceVersion
    case handshakeFailed(String)
    case transport(String)

    public var description: String {
      switch self {
      case .invalidServiceVersion:
        return "The CoreDevice tunnel service did not report a valid service version."
      case .handshakeFailed(let detail):
        return "The CoreDevice tunnel service handshake failed: \(detail)."
      case .transport(let detail):
        return "The CoreDevice tunnel service exchange failed: \(detail)."
      }
    }
  }

  private let service: RemoteXPCService
  private var sequenceNumber: Int64 = 0

  /// The device's remote-pairing identifier reported by the handshake. This
  /// names the saved `remote_<identifier>.plist` record.
  public private(set) var deviceIdentifier: String = ""
  public private(set) var deviceModel: String = ""

  init(service: RemoteXPCService) {
    self.service = service
  }

  /// Receives the pushed `ServiceVersion`, performs the attemptPairVerify
  /// handshake, and captures the device's remote-pairing identity. After this
  /// returns, `nextSequenceNumber` is the sequence the Pair-Setup exchange
  /// must continue from.
  public func connect() throws {
    let initial = try service.receiveValue()
    guard
      let version = initial.dictionaryValue?["ServiceVersion"]?.int64Value,
      version > 0
    else {
      throw Error.invalidServiceVersion
    }

    let handshake: [String: XPCValue] = [
      "request": .dictionary([
        "_0": .dictionary([
          "handshake": .dictionary([
            "_0": .dictionary([
              "hostOptions": .dictionary(["attemptPairVerify": .bool(true)]),
              "wireProtocolVersion": .int64(Self.wireProtocolVersion),
            ])
          ])
        ])
      ])
    ]
    let envelope: [String: XPCValue] = [
      "message": .dictionary(["plain": .dictionary(["_0": .dictionary(handshake)])]),
      "originatedBy": .string("host"),
      "sequenceNumber": .uint64(UInt64(bitPattern: sequenceNumber)),
    ]
    sequenceNumber += 1

    let response = try sendRequest(envelope)
    guard
      let plain = response["message"]?.dictionaryValue?["plain"]?.dictionaryValue,
      let inner = plain["_0"]?.dictionaryValue,
      let top = inner["response"]?.dictionaryValue,
      let one = top["_1"]?.dictionaryValue,
      let handshakeInfo = one["handshake"]?.dictionaryValue,
      let info = handshakeInfo["_0"]?.dictionaryValue,
      let peer = info["peerDeviceInfo"]?.dictionaryValue,
      let identifier = peer["identifier"]?.stringValue,
      !identifier.isEmpty
    else {
      throw Error.handshakeFailed("the device omitted its remote-pairing identity")
    }
    deviceIdentifier = identifier
    deviceModel = peer["model"]?.stringValue ?? ""
  }

  /// The sequence number the Pair-Setup exchange must begin with, after the
  /// handshake consumed sequence zero.
  public var nextSequenceNumber: Int64 {
    sequenceNumber
  }

  /// Builds the transport closure for `CoreDeviceRemotePairing`. Sending with a
  /// reply writes the mangled-type-name envelope and reads one response; sending
  /// without a reply writes only (the `pairVerifyFailed` event); a `nil` send
  /// reads the device's pushed awaiting-consent message.
  public func makeTransport() -> CoreDeviceRemotePairing.Transport {
    { [service] outgoing, waitsForResponse in
      if let outgoing {
        let wrapped: [String: XPCValue] = [
          "mangledTypeName": .string("RemotePairing.ControlChannelMessageEnvelope"),
          "value": .dictionary(outgoing),
        ]
        if waitsForResponse {
          let value = try service.request(wrapped)
          guard
            let dict = value.dictionaryValue,
            let inner = dict["value"]?.dictionaryValue
          else {
            throw CoreDeviceRemotePairing.Error.transport(
              "the tunnelservice response is malformed")
          }
          return inner
        }
        try service.send(wrapped)
        return nil
      }
      let value = try service.receiveValue()
      guard
        let dict = value.dictionaryValue,
        let inner = dict["value"]?.dictionaryValue
      else {
        throw CoreDeviceRemotePairing.Error.transport(
          "the pushed tunnelservice message is malformed")
      }
      return inner
    }
  }

  private func sendRequest(_ envelope: [String: XPCValue]) throws -> [String: XPCValue] {
    let wrapped: [String: XPCValue] = [
      "mangledTypeName": .string("RemotePairing.ControlChannelMessageEnvelope"),
      "value": .dictionary(envelope),
    ]
    let value = try service.request(wrapped)
    guard
      let dict = value.dictionaryValue,
      let inner = dict["value"]?.dictionaryValue
    else {
      throw Error.transport("the tunnelservice response is malformed")
    }
    return inner
  }
}
