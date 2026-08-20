import Foundation

public struct NativeUSBInstaller: Sendable {
  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case deviceNotFound
    case pairRecordMissing
    case invalidIPA
    case afc(String)
    case installation(String)
    case verificationFailed

    public var description: String {
      switch self {
      case .deviceNotFound:
        return "The selected USB device is not available through usbmuxd."
      case .pairRecordMissing:
        return "No trusted usbmux pair record exists for the selected device. Pair it first."
      case .invalidIPA:
        return "The development IPA is missing, empty, or not a regular file."
      case .afc(let detail):
        return "Native AFC staging failed: \(detail)."
      case .installation(let detail):
        return "Native installation proxy failed: \(detail)."
      case .verificationFailed:
        return "Installation completed but the exact bundle identifier was not found on the device."
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
    timeoutSeconds: Double = 300,
    progress: (@Sendable (String) -> Void)? = nil
  ) {
    self.usbmuxAddress = usbmuxAddress
    self.pairingDirectory = pairingDirectory
    self.timeoutSeconds = timeoutSeconds
    self.progress = progress
  }

  public func install(ipa: URL, bundleID: String, udid: String) throws {
    guard
      ipa.isFileURL,
      let values = try? ipa.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true,
      let fileSize = values.fileSize,
      fileSize > 0,
      !bundleID.isEmpty,
      !udid.isEmpty
    else {
      throw Error.invalidIPA
    }

    let mux = USBMuxClient(address: usbmuxAddress, timeoutSeconds: timeoutSeconds)
    guard
      let device = try mux.devices().first(where: {
        $0.connectionType == .usb && $0.serialNumber == udid
      })
    else {
      throw Error.deviceNotFound
    }
    guard let pairData = try pairRecordData(mux: mux, udid: udid) else {
      throw Error.pairRecordMissing
    }
    let pairRecord = try LockdownPairRecord(data: pairData)
    progress?("Loaded the trusted USB pair record.")
    let lockdown = try mux.connectLockdown(deviceID: device.deviceID)
    _ = try lockdown.queryType()
    try lockdown.startSession(using: pairRecord)
    progress?("Established the native lockdown session.")
    defer { try? lockdown.stopSession() }

    let stagingDirectory = "/PublicStaging/stupid-app"
    let stagedPath = "\(stagingDirectory)/\(UUID().uuidString.lowercased()).ipa"
    let afcMetadata = try lockdown.startService("com.apple.afc", pairRecord: pairRecord)
    let afcConnection = try mux.connectService(
      deviceID: device.deviceID,
      service: afcMetadata,
      pairRecord: pairRecord
    )
    var afc = AFCClient(connection: afcConnection)
    progress?("Connected to native AFC staging.")
    try afc.makeDirectory(stagingDirectory, allowExisting: true)
    do {
      try afc.upload(localURL: ipa, remotePath: stagedPath)
      progress?("Staged the development IPA.")
      let installationMetadata = try lockdown.startService(
        "com.apple.mobile.installation_proxy",
        pairRecord: pairRecord
      )
      let installationConnection = try mux.connectService(
        deviceID: device.deviceID,
        service: installationMetadata,
        pairRecord: pairRecord
      )
      let installation = InstallationProxyClient(connection: installationConnection)
      progress?("Connected to native installation proxy.")
      try installation.installDeveloperPackage(at: stagedPath)
      progress?("Installation proxy reported completion.")
      guard try installation.contains(bundleID: bundleID) else {
        throw Error.verificationFailed
      }
      progress?("Verified the installed bundle identifier.")
    } catch {
      try? afc.remove(stagedPath, allowMissing: true)
      throw error
    }
    try afc.remove(stagedPath, allowMissing: true)
    progress?("Removed the staged IPA.")
  }

  private func pairRecordData(mux: USBMuxClient, udid: String) throws -> Data? {
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
}

struct AFCClient {
  static let magic = Data("CFA6LPAA".utf8)
  static let headerSize = 40
  static let maximumPacketSize = 16 * 1_024 * 1_024
  static let writeChunkSize = 1 * 1_024 * 1_024

  enum Operation: UInt64 {
    case status = 0x01
    case data = 0x02
    case readDir = 0x03
    case getFileInfo = 0x0a
    case removePath = 0x08
    case makeDirectory = 0x09
    case fileOpen = 0x0d
    case fileOpenResult = 0x0e
    case read = 0x0f
    case write = 0x10
    case fileClose = 0x14
  }

  private let connection: LockdownServiceConnection
  private var packetNumber: UInt64 = 0

  init(connection: LockdownServiceConnection) {
    self.connection = connection
  }

  /// Lists the entries in a device directory, excluding `.` and `..`.
  mutating func listDirectory(_ path: String) throws -> [String] {
    let response = try exchange(operation: .readDir, payload: Self.cString(path))
    if response.operation == .status {
      try validateStatus(response, allowed: [0])
      return []
    }
    guard response.operation == .data else {
      throw NativeUSBInstaller.Error.afc("read directory returned an unexpected response")
    }
    return response.payload.split(separator: 0x00).compactMap {
      $0.isEmpty ? nil : String(data: Data($0), encoding: .utf8)
    }
  }

  /// Returns `GetFileInfo` attributes for a path. Only the keys surfaced by the
  /// device are present.
  mutating func fileInfo(_ path: String) throws -> [String: String] {
    let response = try exchange(operation: .getFileInfo, payload: Self.cString(path))
    if response.operation == .status {
      try validateStatus(response, allowed: [0])
    }
    guard response.operation == .data else {
      throw NativeUSBInstaller.Error.afc("get file info returned an unexpected response")
    }
    let tokens = response.payload.split(separator: 0x00).compactMap {
      $0.isEmpty ? nil : String(data: Data($0), encoding: .utf8)
    }
    var result: [String: String] = [:]
    var index = 0
    while index + 1 < tokens.count {
      result[tokens[index]] = tokens[index + 1]
      index += 2
    }
    return result
  }

  /// Reads an entire file into memory via `FileRefOpen` + repeated `FileRefRead`.
  mutating func readFileContents(_ path: String) throws -> Data {
    var openPayload = Data()
    // Mode 1 = O_RDONLY.
    Self.appendLittleEndian(UInt64(1), to: &openPayload)
    openPayload.append(Self.cString(path))
    let openResponse = try exchange(operation: .fileOpen, payload: openPayload)
    guard openResponse.operation == .fileOpenResult, openResponse.payload.count == 8 else {
      throw NativeUSBInstaller.Error.afc("file open (read) returned an unexpected response")
    }
    let handle = Self.littleEndianUInt64(openResponse.payload, at: 0)
    guard handle != 0 else {
      throw NativeUSBInstaller.Error.afc("file open (read) returned an invalid handle")
    }
    defer {
      var closePayload = Data()
      Self.appendLittleEndian(handle, to: &closePayload)
      _ = try? exchange(operation: .fileClose, payload: closePayload)
    }

    var result = Data()
    let chunk: UInt64 = 1 * 1_024 * 1_024
    while true {
      var readPayload = Data()
      Self.appendLittleEndian(handle, to: &readPayload)
      Self.appendLittleEndian(chunk, to: &readPayload)
      let response = try exchange(operation: .read, payload: readPayload)
      if response.operation == .status {
        guard response.payload.count == 8 else {
          throw NativeUSBInstaller.Error.afc("file read returned an invalid status response")
        }
        let code = Self.littleEndianUInt64(response.payload, at: 0)
        // 0x0e = END_OF_DATA.
        if code == 0x0e || code == 0 { break }
        throw NativeUSBInstaller.Error.afc("file read failed with status \(code)")
      }
      guard response.operation == .data else {
        throw NativeUSBInstaller.Error.afc("file read returned an unexpected response")
      }
      if response.payload.isEmpty { break }
      result.append(response.payload)
    }
    return result
  }

  mutating func makeDirectory(_ path: String, allowExisting: Bool) throws {
    let response = try exchange(operation: .makeDirectory, payload: Self.cString(path))
    try validateStatus(response, allowed: allowExisting ? [0, 16] : [0])
  }

  mutating func remove(_ path: String, allowMissing: Bool) throws {
    let response = try exchange(operation: .removePath, payload: Self.cString(path))
    try validateStatus(response, allowed: allowMissing ? [0, 8] : [0])
  }

  mutating func upload(localURL: URL, remotePath: String) throws {
    var openPayload = Data()
    Self.appendLittleEndian(UInt64(3), to: &openPayload)
    openPayload.append(Self.cString(remotePath))
    let openResponse = try exchange(operation: .fileOpen, payload: openPayload)
    guard openResponse.operation == .fileOpenResult, openResponse.payload.count == 8 else {
      throw NativeUSBInstaller.Error.afc("file open returned an unexpected response")
    }
    let handle = Self.littleEndianUInt64(openResponse.payload, at: 0)
    guard handle != 0 else {
      throw NativeUSBInstaller.Error.afc("file open returned an invalid handle")
    }

    let file = try FileHandle(forReadingFrom: localURL)
    defer { try? file.close() }
    do {
      while let chunk = try file.read(upToCount: Self.writeChunkSize), !chunk.isEmpty {
        var payload = Data()
        Self.appendLittleEndian(handle, to: &payload)
        payload.append(chunk)
        let response = try exchange(
          operation: .write,
          payload: payload,
          headerLength: Self.headerSize + 8
        )
        try validateStatus(response, allowed: [0])
      }
      var closePayload = Data()
      Self.appendLittleEndian(handle, to: &closePayload)
      try validateStatus(
        try exchange(operation: .fileClose, payload: closePayload),
        allowed: [0]
      )
    } catch {
      var closePayload = Data()
      Self.appendLittleEndian(handle, to: &closePayload)
      _ = try? exchange(operation: .fileClose, payload: closePayload)
      throw error
    }
  }

  mutating func exchange(
    operation: Operation,
    payload: Data,
    headerLength: Int? = nil
  ) throws -> (operation: Operation, payload: Data) {
    let requestNumber = packetNumber
    let packet = try Self.encode(
      operation: operation,
      packetNumber: requestNumber,
      payload: payload,
      headerLength: headerLength
    )
    packetNumber += 1
    try connection.write(packet)
    let responseHeader = try connection.read(count: Self.headerSize)
    let decoded = try Self.decodeHeader(responseHeader)
    guard decoded.packetNumber == requestNumber else {
      throw NativeUSBInstaller.Error.afc("response packet number does not match")
    }
    let responsePayload = try connection.read(count: decoded.entireLength - Self.headerSize)
    return (decoded.operation, responsePayload)
  }

  func validateStatus(
    _ response: (operation: Operation, payload: Data),
    allowed: Set<UInt64>
  ) throws {
    guard response.operation == .status, response.payload.count == 8 else {
      throw NativeUSBInstaller.Error.afc("operation returned an unexpected response")
    }
    let status = Self.littleEndianUInt64(response.payload, at: 0)
    guard allowed.contains(status) else {
      throw NativeUSBInstaller.Error.afc("device returned status \(status)")
    }
  }

  static func encode(
    operation: Operation,
    packetNumber: UInt64,
    payload: Data,
    headerLength: Int? = nil
  ) throws -> Data {
    let entireLength = headerSize + payload.count
    let encodedHeaderLength = headerLength ?? entireLength
    guard
      entireLength <= maximumPacketSize,
      (headerSize...entireLength).contains(encodedHeaderLength)
    else {
      throw NativeUSBInstaller.Error.afc("packet length is invalid")
    }
    var packet = magic
    appendLittleEndian(UInt64(entireLength), to: &packet)
    appendLittleEndian(UInt64(encodedHeaderLength), to: &packet)
    appendLittleEndian(packetNumber, to: &packet)
    appendLittleEndian(operation.rawValue, to: &packet)
    packet.append(payload)
    return packet
  }

  static func decodeHeader(_ data: Data) throws -> (
    entireLength: Int, headerLength: Int, packetNumber: UInt64, operation: Operation
  ) {
    guard data.count == headerSize, Data(data.prefix(8)) == magic else {
      throw NativeUSBInstaller.Error.afc("response header is malformed")
    }
    let entire = littleEndianUInt64(data, at: 8)
    let header = littleEndianUInt64(data, at: 16)
    guard
      entire >= UInt64(headerSize),
      entire <= UInt64(maximumPacketSize),
      header >= UInt64(headerSize),
      header <= entire,
      let operation = Operation(rawValue: littleEndianUInt64(data, at: 32))
    else {
      throw NativeUSBInstaller.Error.afc("response header fields are invalid")
    }
    return (Int(entire), Int(header), littleEndianUInt64(data, at: 24), operation)
  }

  static func cString(_ value: String) -> Data {
    var data = Data(value.utf8)
    data.append(0)
    return data
  }

  static func appendLittleEndian(_ value: UInt64, to data: inout Data) {
    var encoded = value.littleEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
  }

  static func littleEndianUInt64(_ data: Data, at offset: Int) -> UInt64 {
    data.withUnsafeBytes {
      UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
  }
}

struct InstallationProxyClient {
  private let connection: LockdownServiceConnection

  init(connection: LockdownServiceConnection) {
    self.connection = connection
  }

  func installDeveloperPackage(at path: String) throws {
    try connection.sendPlist([
      "Command": "Install",
      "ClientOptions": ["PackageType": "Developer"],
      "PackagePath": path,
    ])
    for _ in 0..<10_000 {
      let response = try connection.receivePlist()
      if let error = response["Error"] as? String {
        throw NativeUSBInstaller.Error.installation(error)
      }
      if response["Status"] as? String == "Complete" {
        return
      }
    }
    throw NativeUSBInstaller.Error.installation("progress response limit exceeded")
  }

  func contains(bundleID: String) throws -> Bool {
    try connection.sendPlist([
      "Command": "Lookup",
      "ClientOptions": [
        "ApplicationType": "Any",
        "BundleIDs": [bundleID],
      ],
    ])
    let response = try connection.receivePlist()
    if let error = response["Error"] as? String {
      throw NativeUSBInstaller.Error.installation(error)
    }
    guard let result = response["LookupResult"] as? [String: Any] else {
      throw NativeUSBInstaller.Error.installation("Lookup omitted LookupResult")
    }
    return result[bundleID] != nil
  }
}
