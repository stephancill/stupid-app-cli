import CLockdownTLS
import Foundation

public struct LockdownPairer: Sendable {
  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case deviceNotFound
    case invalidDeviceIdentity
    case existingRecordInvalid
    case wirelessEnablementFailed

    public var description: String {
      switch self {
      case .deviceNotFound:
        return "The selected USB device is not available through usbmuxd."
      case .invalidDeviceIdentity:
        return "Lockdown did not provide the RSA identity required for native pairing."
      case .existingRecordInvalid:
        return "The existing usbmux pair record is invalid. Retry with explicit record replacement."
      case .wirelessEnablementFailed:
        return "Pairing succeeded, but wireless lockdown could not be enabled and verified."
      }
    }
  }

  public var usbmuxAddress: String?
  public var pairingDirectory: URL?
  public var timeoutSeconds: Double
  public var progress: (@Sendable (String) -> Void)?

  public init(
    usbmuxAddress: String? = nil,
    pairingDirectory: URL? = nil,
    timeoutSeconds: Double = 60,
    progress: (@Sendable (String) -> Void)? = nil
  ) {
    self.usbmuxAddress = usbmuxAddress
    self.pairingDirectory = pairingDirectory
    self.timeoutSeconds = timeoutSeconds
    self.progress = progress
  }

  public func pair(udid: String, replaceExistingRecord: Bool = false) throws
    -> LockdownPairingResult
  {
    let mux = USBMuxClient(address: usbmuxAddress, timeoutSeconds: timeoutSeconds)
    guard
      let device = try mux.devices().first(where: {
        $0.connectionType == .usb && $0.serialNumber == udid
      })
    else {
      throw Error.deviceNotFound
    }

    if !replaceExistingRecord, let existingData = try existingPairRecordData(mux: mux, udid: udid) {
      let existing: LockdownPairRecord
      do {
        existing = try LockdownPairRecord(data: existingData)
      } catch {
        throw Error.existingRecordInvalid
      }
      try enableWireless(mux: mux, device: device, udid: udid, record: existing)
      try persistPairRecord(existingData, udid: udid)
      progress?("Validated the existing native lockdown pairing.")
      return .reusedExistingRecord
    }

    let lockdown = try mux.connectLockdown(deviceID: device.deviceID)
    _ = try lockdown.queryType()
    guard
      let devicePublicKey = try lockdown.getValue(key: "DevicePublicKey") as? Data,
      let wifiAddress = try lockdown.getValue(key: "WiFiAddress") as? String,
      !devicePublicKey.isEmpty,
      !wifiAddress.isEmpty
    else {
      throw Error.invalidDeviceIdentity
    }
    let systemBUID = replaceExistingRecord ? UUID().uuidString : try mux.readBUID()
    let material = try PairingMaterial(
      devicePublicKeyPEM: devicePublicKey,
      systemBUID: systemBUID,
      wifiAddress: wifiAddress
    )
    progress?("Waiting for the device Trust response if prompted...")
    let escrowBag = try lockdown.pair(
      record: material.requestRecord,
      hostName: ProcessInfo.processInfo.hostName,
      timeoutSeconds: timeoutSeconds
    )
    let storedData = try material.serializedRecord(escrowBag: escrowBag)
    let storedRecord = try LockdownPairRecord(data: storedData)
    try persistPairRecord(storedData, udid: udid)
    try enableWireless(
      mux: mux,
      device: try connectedDevice(mux: mux, udid: udid),
      udid: udid,
      record: storedRecord
    )
    return .createdRecord
  }

  private func existingPairRecordData(mux: USBMuxClient, udid: String) throws -> Data? {
    if let pairingDirectory {
      guard !udid.contains("/"), !udid.contains("..") else {
        throw USBMuxClient.Error.invalidInput("device identifier is not a safe file name")
      }
      let local = pairingDirectory.appendingPathComponent("\(udid).plist")
      if FileManager.default.fileExists(atPath: local.path) {
        return try Data(contentsOf: local)
      }
    }
    return try mux.readPairRecord(identifier: udid)
  }

  private func persistPairRecord(_ data: Data, udid: String) throws {
    guard let pairingDirectory else { return }
    guard !udid.contains("/"), !udid.contains("..") else {
      throw USBMuxClient.Error.invalidInput("device identifier is not a safe file name")
    }
    try FileManager.default.createDirectory(
      at: pairingDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: pairingDirectory.path
    )
    let destination = pairingDirectory.appendingPathComponent("\(udid).plist")
    try data.write(to: destination, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: destination.path
    )
    progress?("Stored the native lockdown pair record.")
  }

  private func connectedDevice(mux: USBMuxClient, udid: String) throws -> USBMuxDevice {
    guard
      let device = try mux.devices().first(where: {
        $0.connectionType == .usb && $0.serialNumber == udid
      })
    else {
      throw Error.deviceNotFound
    }
    return device
  }

  private func enableWireless(
    mux: USBMuxClient,
    device: USBMuxDevice,
    udid: String,
    record: LockdownPairRecord
  ) throws {
    let lockdown = try mux.connectLockdown(deviceID: device.deviceID)
    _ = try lockdown.queryType()
    try lockdown.startSession(using: record)
    defer { try? lockdown.stopSession() }
    try lockdown.setValue(
      udid,
      domain: "com.apple.mobile.wireless_lockdown",
      key: "WirelessBuddyID"
    )
    try lockdown.setValue(
      true,
      domain: "com.apple.mobile.wireless_lockdown",
      key: "EnableWifiConnections"
    )
    guard
      let enabled = try lockdown.getValue(
        domain: "com.apple.mobile.wireless_lockdown",
        key: "EnableWifiConnections"
      ) as? Bool,
      enabled
    else {
      throw Error.wirelessEnablementFailed
    }
    progress?("Enabled and verified wireless lockdown.")
  }
}

struct PairingMaterial {
  let hostPrivateKeyPEM: Data
  let requestRecord: [String: Any]

  init(devicePublicKeyPEM: Data, systemBUID: String, wifiAddress: String) throws {
    guard
      !devicePublicKeyPEM.isEmpty,
      !systemBUID.isEmpty,
      !wifiAddress.isEmpty
    else {
      throw LockdownPairer.Error.invalidDeviceIdentity
    }
    var pointer: OpaquePointer?
    let result = devicePublicKeyPEM.withUnsafeBytes {
      stupid_app_lockdown_pairing_material_create(
        $0.bindMemory(to: UInt8.self).baseAddress,
        $0.count,
        &pointer
      )
    }
    guard result == STUPID_APP_LOCKDOWN_TLS_OK.rawValue, let pointer else {
      throw LockdownPairer.Error.invalidDeviceIdentity
    }
    defer { stupid_app_lockdown_pairing_material_destroy(pointer) }
    func data(
      _ accessor: (OpaquePointer?, UnsafeMutablePointer<Int>?) -> UnsafePointer<UInt8>?
    ) throws -> Data {
      var count = 0
      guard let bytes = accessor(pointer, &count), count > 0 else {
        throw LockdownPairer.Error.invalidDeviceIdentity
      }
      return Data(bytes: bytes, count: count)
    }
    let hostCertificate = try data(stupid_app_lockdown_pairing_host_certificate)
    let rootCertificate = try data(stupid_app_lockdown_pairing_root_certificate)
    hostPrivateKeyPEM = try data(stupid_app_lockdown_pairing_host_private_key)
    requestRecord = [
      "DeviceCertificate": try data(stupid_app_lockdown_pairing_device_certificate),
      "HostCertificate": hostCertificate,
      "HostID": UUID().uuidString,
      "RootCertificate": rootCertificate,
      "RootPrivateKey": try data(stupid_app_lockdown_pairing_root_private_key),
      "SystemBUID": systemBUID,
      "WiFiMACAddress": wifiAddress,
    ]
  }

  func serializedRecord(escrowBag: Data?) throws -> Data {
    var record = requestRecord
    record["HostPrivateKey"] = hostPrivateKeyPEM
    if let escrowBag { record["EscrowBag"] = escrowBag }
    return try PropertyListSerialization.data(
      fromPropertyList: record,
      format: .xml,
      options: 0
    )
  }
}
