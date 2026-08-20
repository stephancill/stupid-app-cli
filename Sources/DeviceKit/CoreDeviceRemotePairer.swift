import Foundation

/// Performs the native CoreDevice remote-pair bootstrap over USB, replacing
/// the Python `pair-usb` helper. It establishes the privileged CoreDevice USB
/// tunnel, connects the RSD tunnel service, completes the ServiceVersion and
/// attemptPairVerify handshakes, runs the SRP-3072 Pair-Setup exchange, and
/// writes the owner-only `remote_<identifier>.plist` record that the network
/// run path consumes.
public struct CoreDeviceRemotePairer: Sendable {
  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case serviceUnavailable(String)
    case pairingFailed(String)
    case recordWriteFailed(String)

    public var description: String {
      switch self {
      case .serviceUnavailable(let detail):
        return "The CoreDevice tunnel service is unavailable: \(detail)."
      case .pairingFailed(let detail):
        return "CoreDevice remote pairing failed: \(detail)."
      case .recordWriteFailed(let detail):
        return "The remote pairing record could not be stored: \(detail)."
      }
    }
  }

  public var usbmuxAddress: String?
  public var pairingDirectory: URL
  public var timeoutSeconds: Double
  public var progress: (@Sendable (String) -> Void)?

  public init(
    usbmuxAddress: String? = nil,
    pairingDirectory: URL,
    timeoutSeconds: Double = 60,
    progress: (@Sendable (String) -> Void)? = nil
  ) {
    self.usbmuxAddress = usbmuxAddress
    self.pairingDirectory = pairingDirectory
    self.timeoutSeconds = timeoutSeconds
    self.progress = progress
  }

  /// Pairs the selected USB device and stores the remote pairing record.
  public func pair(udid: String) throws {
    let tunnel = try USBCoreDeviceTunnel(
      usbmuxAddress: usbmuxAddress,
      pairingDirectory: pairingDirectory,
      timeoutSeconds: timeoutSeconds,
      udid: udid,
      progress: progress
    )
    defer { tunnel.close() }

    let serviceConnection: RemoteXPCService
    do {
      serviceConnection = try tunnel.session.connect(service: CoreDeviceTunnelService.serviceName)
    } catch {
      throw Error.serviceUnavailable("\(error)")
    }
    let tunnelService = CoreDeviceTunnelService(service: serviceConnection)
    try tunnelService.connect()
    progress?("Connected to the CoreDevice tunnel service.")

    let hostname = ProcessInfo.processInfo.hostName
    let hostIdentifier = RemotePairing.generateHostID(hostname: hostname)
    let pairing = CoreDeviceRemotePairing()
    let transport = tunnelService.makeTransport()
    let validation = try pairing.validatePairing(
      transport: transport,
      identifier: hostIdentifier,
      recordPrivateKey: recordPrivateKey(identifier: tunnelService.deviceIdentifier),
      initialSequenceNumber: tunnelService.nextSequenceNumber
    )
    guard !validation.alreadyPaired else {
      progress?("The device already recognizes this host; no Pair-Setup is needed.")
      return
    }
    let record = try pairing.pair(
      transport: transport,
      identifier: hostIdentifier,
      hostname: hostname,
      initialSequenceNumber: validation.nextSequenceNumber
    )
    progress?("Pair-Setup completed; storing the remote pairing record.")

    let identifier = tunnelService.deviceIdentifier
    guard !identifier.isEmpty, !identifier.contains("/"), !identifier.contains("..") else {
      throw Error.recordWriteFailed("the device identifier is not a safe file name")
    }
    try persist(record, identifier: identifier)
    try RemotePairing.saveUdidMapping(identifier: identifier, udid: udid, in: pairingDirectory)
    progress?("Stored the CoreDevice remote pairing record.")
  }

  private func recordPrivateKey(identifier: String) -> Data? {
    guard !identifier.isEmpty, !identifier.contains("/"), !identifier.contains("..") else {
      return nil
    }
    let url = RemotePairing.recordURL(identifier: identifier, in: pairingDirectory)
    guard
      FileManager.default.fileExists(atPath: url.path),
      let record = try? RemotePairing.Record.load(from: url)
    else {
      return nil
    }
    return record.privateKey
  }

  private func persist(_ record: CoreDeviceRemotePairing.SavedRecord, identifier: String) throws {
    let data: Data
    do {
      data = try record.plistData()
    } catch {
      throw Error.recordWriteFailed("the record could not be serialized")
    }
    do {
      try FileManager.default.createDirectory(
        at: pairingDirectory,
        withIntermediateDirectories: true
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: pairingDirectory.path
      )
      let destination = pairingDirectory.appendingPathComponent("remote_\(identifier).plist")
      try data.write(to: destination, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: destination.path
      )
      try Self.restoreInvokingUserOwnership(of: destination)
    } catch let error as Error {
      throw error
    } catch {
      throw Error.recordWriteFailed(String(describing: error))
    }
  }

  /// When run through the privileged helper under sudo, hand the record back
  /// to the invoking user so the unprivileged network run path can read it.
  static func restoreInvokingUserOwnership(of url: URL) throws {
    guard
      let uidText = ProcessInfo.processInfo.environment["SUDO_UID"],
      let gidText = ProcessInfo.processInfo.environment["SUDO_GID"],
      let uid = uid_t(uidText),
      let gid = gid_t(gidText)
    else {
      return
    }
    _ = chown(url.path, uid, gid)
  }
}
