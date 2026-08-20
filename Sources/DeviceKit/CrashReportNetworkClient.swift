import Foundation

/// Network (wireless/CoreDevice tunnel) crash-report pull over the RSD
/// `com.apple.crashreportcopymobile.shim.remote` service. It reuses the same
/// remote-pairing tunnel, RSD, and AFC primitives as `NativeNetworkRunner`. No
/// host tool (devicectl/Xcode/`pymobiledevice3`) is used; the tunnel requires the
/// privileged `coredevice-helper` boundary on macOS (TUN creation), so callers
/// run under `--sudo` there, and stay in-process on Linux.
public struct CrashReportNetworkClient: Sendable {
  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case noRemoteRecord
    case noAdvertisement
    case noCandidates
    case allFailed(String)
    case noReports

    public var description: String {
      switch self {
      case .noRemoteRecord:
        return "No remote pairing record exists. Run `stupid-app device pair --usb` first."
      case .noAdvertisement:
        return
          "No iPhone remote-pairing service was discovered. Confirm the phone is unlocked, "
          + "on the same network."
      case .noCandidates:
        return "No usable remote-pairing candidates were discovered."
      case .allFailed(let detail):
        return "No network tunnel reached the selected device (\(detail))."
      case .noReports:
        return "No crash-log report matched the requested criteria on the device."
      }
    }
  }

  public var pairingDirectory: URL
  public var udid: String
  public var discoveryTimeoutSeconds: Double
  public var progress: (@Sendable (String) -> Void)?

  public init(
    pairingDirectory: URL,
    udid: String,
    discoveryTimeoutSeconds: Double = 15,
    progress: (@Sendable (String) -> Void)? = nil
  ) {
    self.pairingDirectory = pairingDirectory
    self.udid = udid
    self.discoveryTimeoutSeconds = discoveryTimeoutSeconds
    self.progress = progress
  }

  /// Pulls the newest crash report matching `nameFilter` (or the newest overall)
  /// over the wireless tunnel and returns it parsed. The tunnel is kept alive for
  /// the duration of the read.
  public func latestParsedReport(nameFilter: String?) throws -> CrashReport {
    let identifiers = try RemotePairing.pairedIdentifiers(in: pairingDirectory)
    guard !identifiers.isEmpty else { throw Error.noRemoteRecord }

    let advertisements = try RemotepairingDiscovery().browse(timeout: discoveryTimeoutSeconds)
    guard !advertisements.isEmpty else { throw Error.noAdvertisement }

    var candidates: [(identifier: String, address: String, port: Int)] = []
    var seen = Set<String>()
    for advertisement in advertisements {
      guard let port = advertisement.port else { continue }
      for address in advertisement.addresses.sorted() {
        for identifier in identifiers {
          let key = "\(identifier)|\(address.scopedIP)|\(port)"
          guard !seen.contains(key) else { continue }
          seen.insert(key)
          candidates.append((identifier, address.scopedIP, port))
        }
      }
    }
    guard !candidates.isEmpty else { throw Error.noCandidates }

    var failures: [String] = []
    for (index, candidate) in candidates.enumerated() {
      do {
        progress?("Trying remote-pairing candidate \(index + 1).")
        return try readReportCandidate(candidate, nameFilter: nameFilter)
      } catch {
        failures.append("candidate \(index + 1): \(redact(error))")
      }
    }
    throw Error.allFailed(failures.suffix(20).joined(separator: ", "))
  }

  /// Opens the tunnel, connects the crash-report service, and performs the read
  /// while the tunnel and relay are alive.
  private func readReportCandidate(
    _ candidate: (identifier: String, address: String, port: Int),
    nameFilter: String?
  ) throws -> CrashReport {
    let recordURL = RemotePairing.recordURL(
      identifier: candidate.identifier, in: pairingDirectory)
    guard FileManager.default.fileExists(atPath: recordURL.path) else {
      throw RemotePairing.Error.invalidRecord("\(candidate.identifier) record is absent")
    }
    let record = try RemotePairing.Record.load(from: recordURL)

    let client = RemotePairingTunnelClient(
      host: candidate.address, port: UInt16(candidate.port),
      timeoutSeconds: discoveryTimeoutSeconds)
    let outcome = try client.establish(record: record)
    progress?("Remote pairing verified; opening the TCP tunnel listener.")

    let tunnel = try PersistentCoreDeviceTunnel(
      host: candidate.address,
      port: Int(outcome.listenPort),
      preSharedKey: outcome.preSharedKey,
      timeoutSeconds: discoveryTimeoutSeconds)
    let relay = try tunnel.startRelay()
    progress?(
      "Network tunnel established (client \(tunnel.handshake.clientAddress) server \(tunnel.handshake.serverAddress):\(tunnel.handshake.serverRSDPort))."
    )

    let rsd = RSDClient(
      host: tunnel.handshake.serverAddress,
      port: tunnel.handshake.serverRSDPort,
      timeoutSeconds: discoveryTimeoutSeconds)
    let session = try rsd.open()
    guard session.peerInfo.udid == udid else {
      throw RemotePairing.Error.pairing("the tunnel resolved a different device")
    }
    progress?("Resolved the remote service discovery peer.")

    defer {
      relay.stop()
      tunnel.stop()
    }

    let connection = try rsd.startLockdownService(
      CrashReportClient.copyMobileNetworkServiceName, peerInfo: session.peerInfo)
    progress?("Connected to the crash-report service over the tunnel.")

    var afc = AFCClient(connection: connection)
    return try CrashReportClient.latestParsedReport(
      af: &afc, nameFilter: nameFilter, progress: progress)
  }

  private func redact(_ error: Swift.Error) -> String {
    RemotePairing.redact(detail: String(describing: error), udid: udid)
  }
}