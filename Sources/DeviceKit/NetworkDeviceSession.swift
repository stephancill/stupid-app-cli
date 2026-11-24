import Foundation

/// Opens the CoreDevice network tunnel to a paired device and runs `body` with its RSD
/// client and peer info. Shared by the network diagnostics (log stream, app container).
public enum NetworkDeviceSession {
  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case noTunnel(String)

    public var description: String {
      switch self {
      case .noTunnel(let detail):
        return "No network tunnel reached the selected device (\(detail))."
      }
    }
  }

  public static func with<T>(
    udid: String, pairingDirectory: URL, discoveryTimeoutSeconds: Double = 5,
    sessionTimeoutSeconds: Double = 3600,
    _ body: (RSDClient, RSDClient.PeerInfo) throws -> T
  ) throws -> T {
    let identifiers = try RemotePairing.resolveIdentifiers(
      forRequestedUdid: udid, in: pairingDirectory)
    var failures: [String] = []
    for advertisement in try RemotepairingDiscovery().browse(timeout: discoveryTimeoutSeconds) {
      guard let port = advertisement.port else { continue }
      for address in advertisement.addresses.sorted() {
        for identifier in identifiers {
          let tunnel: UserspaceCoreDeviceTunnel
          let rsd: RSDClient
          let peerInfo: RSDClient.PeerInfo
          do {
            let record = try RemotePairing.Record.load(
              from: RemotePairing.recordURL(identifier: identifier, in: pairingDirectory))
            let outcome = try RemotePairingTunnelClient(
              host: address.scopedIP, port: UInt16(port), timeoutSeconds: 15
            ).establish(record: record)
            tunnel = try UserspaceCoreDeviceTunnel(
              host: address.scopedIP, port: Int(outcome.listenPort),
              preSharedKey: outcome.preSharedKey, timeoutSeconds: sessionTimeoutSeconds)
            rsd = tunnel.rsd(timeoutSeconds: sessionTimeoutSeconds)
            peerInfo = try rsd.connect()
          } catch {
            failures.append(String(describing: error))
            continue
          }
          defer { tunnel.closeTunnel() }
          guard peerInfo.udid == udid else {
            failures.append("the tunnel resolved a different device")
            continue
          }
          return try body(rsd, peerInfo)
        }
      }
    }
    throw Error.noTunnel(failures.joined(separator: "; "))
  }
}

/// Reads an installed development app's data container over the network through
/// `house_arrest` (`VendContainer`), which then speaks AFC rooted at the container.
public struct NetworkAppContainer: Sendable {
  public static let serviceName = "com.apple.mobile.house_arrest.shim.remote"

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case vendFailed(String)

    public var description: String {
      switch self {
      case .vendFailed(let detail):
        return "house_arrest could not vend the app container: \(detail)."
      }
    }
  }

  public enum Action: Sendable {
    case list(String)
    case read(String)
  }

  public var udid: String
  public var bundleID: String
  public var pairingDirectory: URL

  public init(udid: String, bundleID: String, pairingDirectory: URL) {
    self.udid = udid
    self.bundleID = bundleID
    self.pairingDirectory = pairingDirectory
  }

  /// Lists a container directory (entry names) or reads a file, by container path such as
  /// `Library/Caches`.
  public func perform(_ action: Action) throws -> Data {
    try NetworkDeviceSession.with(
      udid: udid, pairingDirectory: pairingDirectory, sessionTimeoutSeconds: 120
    ) { rsd, peerInfo in
      let connection = try rsd.startLockdownService(Self.serviceName, peerInfo: peerInfo)
      try connection.sendPlist(["Command": "VendContainer", "Identifier": bundleID])
      let response = try connection.receivePlist()
      if let error = response["Error"] as? String {
        throw Error.vendFailed(error)
      }
      guard response["Status"] as? String == "Complete" else {
        throw Error.vendFailed("\(response)")
      }
      var afc = AFCClient(connection: connection)
      switch action {
      case .list(let path):
        let names = try afc.listDirectory("/" + path)
          .filter { $0 != "." && $0 != ".." }
        return Data(names.joined(separator: "\n").utf8)
      case .read(let path):
        return try afc.readFileContents("/" + path)
      }
    }
  }
}
