import Foundation

/// Native crash-report pull over an AFC-based lockdown service
/// (`com.apple.crashreportcopymobile` over the USB/usbmux path). It lists the
/// device's crash-report directory and reads `.ips` files, then returns them as
/// parsed `CrashReport` values. No host tool (devicectl/Xcode/`pymobiledevice3`)
/// is required and no privileged tunnel is used: the service connects over the
/// same lockdown session the USB installer uses.
public struct CrashReportClient: Sendable {
  public static let copyMobileServiceName = "com.apple.crashreportcopymobile"
  public static let copyMobileNetworkServiceName = "com.apple.crashreportcopymobile.shim.remote"

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case deviceNotFound
    case pairRecordMissing
    case service(String)
    case noReports
    case invalidReport(String)

    public var description: String {
      switch self {
      case .deviceNotFound:
        return "The selected USB device is not available through usbmuxd."
      case .pairRecordMissing:
        return "No trusted usbmux pair record exists for the selected device. Pair it first."
      case .service(let detail):
        return "The crash-report service failed: \(detail)."
      case .noReports:
        return "No crash-log report matched the requested criteria on the device."
      case .invalidReport(let detail):
        return "A crash report could not be parsed: \(detail)."
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

  /// Lists crash-report file names on the device root directory over USB.
  public func listReportNames(udid: String) throws -> [String] {
    var afc = try openReportAFC(udid: udid)
    return try afc.listDirectory("/")
  }

  /// Pulls over USB the newest crash report matching `nameFilter` (substring),
  /// or the newest overall when `nameFilter` is nil.
  public func latestParsedReportUSB(udid: String, nameFilter: String?) throws -> CrashReport {
    var afc = try openReportAFC(udid: udid)
    return try Self.latestParsedReport(af: &afc, nameFilter: nameFilter, progress: progress)
  }

  /// Pulls over USB all crash reports matching `nameFilter`.
  public func reportBundlesUSB(udid: String, nameFilter: String?) throws -> [CrashReport] {
    var afc = try openReportAFC(udid: udid)
    return try Self.reportBundles(af: &afc, nameFilter: nameFilter)
  }

  /// Shared "pick the newest by embedded timestamp and parse it" logic over an
  /// already-open crash-report AFC client.
  static func latestParsedReport(
    af afc: inout AFCClient,
    nameFilter: String?,
    progress: (@Sendable (String) -> Void)?
  ) throws -> CrashReport {
    let names = try afc.listDirectory("/")
    var candidates: [String] = []
    for entry in names {
      let lower = entry.lowercased()
      guard lower.hasSuffix(".ips") || lower.hasSuffix(".panic") else { continue }
      if let nameFilter {
        guard lower.contains(nameFilter.lowercased()) else { continue }
      }
      candidates.append(entry)
    }
    guard !candidates.isEmpty else {
      throw Error.noReports
    }
    let newest = candidates.max { lhs, rhs in
      Self.timestamp(of: lhs) < Self.timestamp(of: rhs)
    } ?? candidates.first!
    progress?("Reading \(newest).")
    let data = try afc.readFileContents("/\(newest)")
    guard let buffer = String(data: data, encoding: .utf8) else {
      throw Error.invalidReport("\(newest) is not UTF-8 text")
    }
    var report: CrashReport
    do {
      report = try CrashReportParsing.parse(buffer)
    } catch {
      throw Error.invalidReport("\(newest): \(String(describing: error))")
    }
    report.filename = newest
    return report
  }

  /// Shared "pull and parse all matching reports" logic over an open AFC client.
  static func reportBundles(
    af afc: inout AFCClient, nameFilter: String?
  ) throws -> [CrashReport] {
    let names = try afc.listDirectory("/")
    var results: [CrashReport] = []
    for entry in names.sorted() {
      let lower = entry.lowercased()
      guard lower.hasSuffix(".ips") || lower.hasSuffix(".panic") else { continue }
      if let nameFilter, !lower.contains(nameFilter.lowercased()) { continue }
      guard let data = try? afc.readFileContents("/\(entry)"),
        let buffer = String(data: data, encoding: .utf8)
      else { continue }
      if let parsed = try? CrashReportParsing.parse(buffer) {
        var report = parsed
        report.filename = entry
        results.append(report)
      }
    }
    return results
  }

  /// Extracts a comparable timestamp from an `.ips` file name such as
  /// `App.cpu_resource-2026-08-20-143950.ips`, or `.distantPast` when absent.
  private static func timestamp(of filename: String) -> Date {
    let pattern = #"-(\d{4})-(\d{2})-(\d{2})-(\d{6})\."#
    guard
      let range = filename.range(of: pattern, options: .regularExpression)
    else { return .distantPast }
    let match = String(filename[range])
    let digits = match.filter(\.isNumber)
    guard digits.count == 14 else { return .distantPast }

    let year = Int(digits.prefix(4)) ?? 0
    let month = Int(digits.dropFirst(4).prefix(2)) ?? 0
    let day = Int(digits.dropFirst(6).prefix(2)) ?? 0
    let hour = Int(digits.dropFirst(8).prefix(2)) ?? 0
    let minute = Int(digits.dropFirst(10).prefix(2)) ?? 0
    let second = Int(digits.dropFirst(12).prefix(2)) ?? 0

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar.date(
      from: DateComponents(
        year: year, month: month, day: day,
        hour: hour, minute: minute, second: second)
    ) ?? .distantPast
  }

  private func openReportAFC(udid: String) throws -> AFCClient {
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
    do {
      try lockdown.startSession(using: pairRecord)
      defer { try? lockdown.stopSession() }
      let metadata = try lockdown.startService(Self.copyMobileServiceName, pairRecord: pairRecord)
      let connection = try mux.connectService(
        deviceID: device.deviceID,
        service: metadata,
        pairRecord: pairRecord
      )
      return AFCClient(connection: connection)
    } catch {
      throw Error.service(String(describing: error))
    }
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