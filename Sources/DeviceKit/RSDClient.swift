import Foundation

/// A Remote Service Discovery (RSD) client speaking RemoteXPC's HTTP/2
/// framing over an established TCP tunnel to a CoreDevice endpoint.
public struct RSDClient: Sendable {
  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case connectionFailed(Int32)
    case timedOut
    case invalidPeerInfo(String)
    case serviceNotFound(String)
    case invalidService(String)
    case remoteXPC(String)

    public var description: String {
      switch self {
      case .connectionFailed(let code):
        return
          "Could not connect to the Remote Service Discovery endpoint (public error code \(code))."
      case .timedOut:
        return "The Remote Service Discovery exchange timed out."
      case .invalidPeerInfo(let detail):
        return "The RSD peer information is invalid: \(detail)."
      case .serviceNotFound(let name):
        return "The RSD peer does not offer the service '\(name)'."
      case .invalidService(let detail):
        return "The RSD service metadata is invalid: \(detail)."
      case .remoteXPC(let detail):
        return "The RemoteXPC exchange failed: \(detail)."
      }
    }
  }

  /// Ports resolved from the peer's advertised service table.
  public struct Service: Equatable, Sendable {
    public var port: UInt64
    public var usesRemoteXPC: Bool
  }

  public struct PeerInfo: Equatable, Sendable {
    public var udid: String
    public var productType: String
    public var services: [String: Service]
  }

  private let host: String
  private let port: Int
  private let timeoutSeconds: Double

  public init(host: String, port: Int, timeoutSeconds: Double = 15) {
    self.host = host
    self.port = port
    self.timeoutSeconds = timeoutSeconds
  }

  /// Connects, performs the RemoteXPC handshake, and resolves the peer's
  /// advertised identity and services.
  public func connect() throws -> PeerInfo {
    let socket = try SocketConnection(
      address: "\(host):\(port)",
      timeoutSeconds: timeoutSeconds
    )
    let remote = RemoteXPCConnection(connection: socket)
    do {
      try remote.start()
      let peerInfo = try remote.receiveResponse()
      let decoded = try Self.peerInfo(from: peerInfo)
      return decoded
    } catch {
      socket.closeImmediately()
      throw error
    }
  }

  /// Opens a RSD session that owns the control connection. Keeping it open for
  /// the duration of nested service calls is required: the device tears the
  /// tunnel down if the RSD control connection closes, so the launch response
  /// would never be delivered.
  public func open() throws -> RSDSession {
    let socket = try SocketConnection(
      address: "\(host):\(port)",
      timeoutSeconds: timeoutSeconds
    )
    let remote = RemoteXPCConnection(connection: socket)
    do {
      try remote.start()
      let peerInfo = try Self.peerInfo(from: try remote.receiveResponse())
      return RSDSession(
        socket: socket, host: host, timeoutSeconds: timeoutSeconds, peerInfo: peerInfo)
    } catch {
      socket.closeImmediately()
      throw error
    }
  }

  /// Opens a RemoteXPC connection to the advertised service port.
  public func connect(service name: String, peerInfo: PeerInfo) throws -> RemoteXPCService {
    guard let service = peerInfo.services[name] else {
      throw Error.serviceNotFound(name)
    }
    let socket = try SocketConnection(
      address: "\(host):\(service.port)",
      timeoutSeconds: timeoutSeconds
    )
    let remote = RemoteXPCConnection(connection: socket)
    do {
      try remote.start()
      return RemoteXPCService(remote: remote, socket: socket)
    } catch {
      socket.closeImmediately()
      throw error
    }
  }

  /// Performs the RSDCheckin exchange for a lockdown-style service.
  public func startLockdownService(
    _ name: String,
    peerInfo: PeerInfo,
    label: String = "stupid-app"
  ) throws -> LockdownServiceConnection {
    guard let service = peerInfo.services[name] else {
      throw Error.serviceNotFound(name)
    }
    let socket = try SocketConnection(
      address: "\(host):\(service.port)",
      timeoutSeconds: timeoutSeconds
    )
    let connection = LockdownServiceConnection(connection: socket)
    do {
      try connection.sendPlist([
        "Label": label,
        "ProtocolVersion": "2",
        "Request": "RSDCheckin",
      ])
      let checkin = try connection.receivePlist()
      guard checkin["Request"] as? String == "RSDCheckin" else {
        throw Error.invalidService("RSDCheckin returned an unexpected response")
      }
      let startService = try connection.receivePlist()
      guard startService["Request"] as? String == "StartService" else {
        throw Error.invalidService("RSDCheckin did not confirm StartService")
      }
      if let error = startService["Error"] as? String {
        throw Error.invalidService("RSDCheckin failed for \(name): \(error)")
      }
      return connection
    } catch {
      socket.closeImmediately()
      throw error
    }
  }

  static func peerInfo(from value: XPCValue) throws -> PeerInfo {
    guard let root = value.dictionaryValue else {
      throw Error.invalidPeerInfo("the peer did not return a dictionary")
    }
    guard let properties = root["Properties"]?.dictionaryValue else {
      throw Error.invalidPeerInfo("Properties is missing")
    }
    guard let udid = properties["UniqueDeviceID"]?.stringValue, !udid.isEmpty else {
      throw Error.invalidPeerInfo("UniqueDeviceID is missing")
    }
    let productType = properties["ProductType"]?.stringValue ?? ""
    var services: [String: Service] = [:]
    if let advertised = root["Services"]?.dictionaryValue {
      for (name, entry) in advertised {
        guard let metadata = entry.dictionaryValue else {
          throw Error.invalidService("\(name) is not a dictionary")
        }
        let rawPort: UInt64
        if let port = metadata["Port"]?.uint64Value {
          rawPort = port
        } else if let port = metadata["Port"]?.int64Value, port > 0 {
          rawPort = UInt64(port)
        } else if let port = metadata["Port"]?.stringValue, let parsed = UInt64(port) {
          rawPort = parsed
        } else {
          continue
        }
        guard (1...65_535).contains(rawPort) else {
          continue
        }
        let usesRemoteXPC =
          metadata["Properties"]?.dictionaryValue?["UsesRemoteXPC"]?.boolValue
          ?? false
        services[name] = Service(port: rawPort, usesRemoteXPC: usesRemoteXPC)
      }
    }
    return PeerInfo(udid: udid, productType: productType, services: services)
  }
}

/// An active RSD session that keeps the control connection open for the
/// lifetime of nested service calls. Closing it releases the control socket.
public final class RSDSession: @unchecked Sendable {
  private let socket: SocketConnection
  private let host: String
  private let timeoutSeconds: Double

  public let peerInfo: RSDClient.PeerInfo

  init(
    socket: SocketConnection,
    host: String,
    timeoutSeconds: Double,
    peerInfo: RSDClient.PeerInfo
  ) {
    self.socket = socket
    self.host = host
    self.timeoutSeconds = timeoutSeconds
    self.peerInfo = peerInfo
  }

  deinit {
    socket.closeImmediately()
  }

  /// Opens a RemoteXPC connection to an advertised service while this session
  /// (and therefore the tunnel control connection) stays open.
  public func connect(service name: String) throws -> RemoteXPCService {
    guard let service = peerInfo.services[name] else {
      throw RSDClient.Error.serviceNotFound(name)
    }
    let socket = try SocketConnection(
      address: "\(host):\(service.port)",
      timeoutSeconds: timeoutSeconds
    )
    let remote = RemoteXPCConnection(connection: socket)
    do {
      try remote.start()
      return RemoteXPCService(remote: remote, socket: socket)
    } catch {
      socket.closeImmediately()
      throw error
    }
  }
}

/// An established RemoteXPC connection to an RSD service, owning the socket.
public final class RemoteXPCService: @unchecked Sendable {
  private let remote: RemoteXPCConnection
  private let socket: SocketConnection

  init(remote: RemoteXPCConnection, socket: SocketConnection) {
    self.remote = remote
    self.socket = socket
  }

  deinit {
    socket.closeImmediately()
  }

  /// Reads the next message the peer pushes without a prior request. Used by
  /// the CoreDevice tunnel service to receive the initial `ServiceVersion`.
  public func receiveValue() throws -> XPCValue {
    try remote.receiveResponse()
  }

  /// Sends a request and reads the matching response, without the reply flag.
  /// This matches the CoreDevice tunnel service envelope exchange.
  public func request(_ body: [String: XPCValue]) throws -> XPCValue {
    try remote.sendRequest(body, wantingReply: false)
    return try remote.receiveResponse()
  }

  /// Sends an envelope without reading a response. The CoreDevice tunnel
  /// service's `pairVerifyFailed` event is fire-and-forget.
  public func send(_ body: [String: XPCValue]) throws {
    try remote.sendRequest(body, wantingReply: false)
  }

  public func invoke(_ body: [String: XPCValue]) throws -> XPCValue {
    try remote.sendRequest(body, wantingReply: true)
    return try remote.receiveResponse()
  }
}
