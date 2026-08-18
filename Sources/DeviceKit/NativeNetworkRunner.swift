import Foundation

/// The native CoreDevice network run path. It discovers the device by mDNS,
/// establishes a remote-pairing tunnel from a saved record, and performs
/// installation and launch over RSD. This replaces the Python `run-network`
/// helper, so the deployment loop no longer needs Python.
public struct NativeNetworkRunner: Sendable {
  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case noRemoteRecord
    case noAdvertisement
    case noCandidates
    case allFailed(String)

    public var description: String {
      switch self {
      case .noRemoteRecord:
        return "No remote pairing record exists. Run `stupid-app device pair --usb` first."
      case .noAdvertisement:
        return
          "No iPhone remote-pairing service was discovered. Confirm the phone is unlocked, "
          + "on the same network, and disconnected from USB."
      case .noCandidates:
        return "No usable remote-pairing candidates were discovered."
      case .allFailed(let detail):
        return "No network tunnel reached the selected device (\(detail))."
      }
    }
  }

  public var pairingDirectory: URL
  public var udid: String
  public var ipa: URL
  public var bundleID: String
  public var discoveryTimeoutSeconds: Double
  public var installTimeoutSeconds: Double
  public var launchTimeoutSeconds: Double
  public var progress: (@Sendable (String) -> Void)?

  public init(
    pairingDirectory: URL,
    udid: String,
    ipa: URL,
    bundleID: String,
    discoveryTimeoutSeconds: Double = 15,
    installTimeoutSeconds: Double = 300,
    launchTimeoutSeconds: Double = 60,
    progress: (@Sendable (String) -> Void)? = nil
  ) {
    self.pairingDirectory = pairingDirectory
    self.udid = udid
    self.ipa = ipa
    self.bundleID = bundleID
    self.discoveryTimeoutSeconds = discoveryTimeoutSeconds
    self.installTimeoutSeconds = installTimeoutSeconds
    self.launchTimeoutSeconds = launchTimeoutSeconds
    self.progress = progress
  }

  public func installAndLaunch() throws -> Int64 {
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
        let pid = try installAndLaunchCandidate(candidate)
        return pid
      } catch {
        failures.append("candidate \(index + 1): \(redact(error))")
      }
    }
    throw Error.allFailed(failures.suffix(20).joined(separator: ", "))
  }

  private func installAndLaunchCandidate(
    _ candidate: (identifier: String, address: String, port: Int)
  ) throws -> Int64 {
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
      timeoutSeconds: max(discoveryTimeoutSeconds, launchTimeoutSeconds))
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

    try install(rsd: rsd, peerInfo: session.peerInfo)
    progress?("Installed and verified the application over the network.")

    let service = try session.connect(service: AppServiceClient.serviceName)
    let appService = AppServiceClient(service: service)
    let pid = try appService.launchApplication(bundleID: bundleID)
    progress?("Launched the application (pid \(pid)).")
    return pid
  }

  private func install(rsd: RSDClient, peerInfo: RSDClient.PeerInfo) throws {
    let afcName = "com.apple.afc.shim.remote"
    let installName = "com.apple.mobile.installation_proxy.shim.remote"
    let afcConnection = try rsd.startLockdownService(afcName, peerInfo: peerInfo)
    var afc = AFCClient(connection: afcConnection)
    let stagingDirectory = "/PublicStaging/stupid-app"
    let stagedPath = "\(stagingDirectory)/\(UUID().uuidString.lowercased()).ipa"
    progress?("Connected to native AFC staging over the tunnel.")
    try afc.makeDirectory(stagingDirectory, allowExisting: true)
    do {
      try afc.upload(localURL: ipa, remotePath: stagedPath)
      progress?("Staged the development IPA.")
      let installationConnection = try rsd.startLockdownService(
        installName, peerInfo: peerInfo)
      let installation = InstallationProxyClient(connection: installationConnection)
      progress?("Connected to the network installation proxy.")
      try installation.installDeveloperPackage(at: stagedPath)
      progress?("Installation proxy reported completion.")
      guard try installation.contains(bundleID: bundleID) else {
        throw NativeUSBInstaller.Error.verificationFailed
      }
      progress?("Verified the installed bundle identifier.")
    } catch {
      try? afc.remove(stagedPath, allowMissing: true)
      throw error
    }
    try afc.remove(stagedPath, allowMissing: true)
    progress?("Removed the staged IPA.")
  }

  private func redact(_ error: Swift.Error) -> String {
    RemotePairing.redact(detail: String(describing: error), udid: udid)
  }
}
