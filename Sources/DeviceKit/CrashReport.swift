import Foundation

/// A structured crash report in Apple's `.ips` (Interprocess Property Standard) format.
///
/// The format is a metadata JSON object on the first line followed by a data
/// payload. For user-mode and jetsam reports the payload is itself JSON; legacy
/// panic/binary reports use a human-readable text format. The parser is
/// intentionally tolerant: it always surfaces the shared metadata and a best-effort
/// diagnostic summary, matching `pycrashreport`'s behavior without depending on
/// Python.
public struct CrashReport: Sendable, Equatable, Codable {
  /// The `.ips` file name as reported by the device, if known.
  public var filename: String?
  /// Incident identifier from the metadata, when present.
  public var incidentID: String?
  /// Report process name (`name`), when present.
  public var name: String?
  /// The report's `bug_type` string (e.g. `crash`, `"309"`, `"298"`, `"get-list"`).
  public var bugType: String?
  /// Device/bundle identifier (`app_name` / `bundle_id`), when present.
  public var appName: String?
  /// Bundle identifier (`sender`/`bundleID`), when present.
  public var bundleID: String?
  /// `os_version` string, when present.
  public var osVersion: String?
  /// ISO-8601 timestamp string from metadata, when present.
  public var timestamp: String?

  /// JSON parse fields from the data payload.
  public var exceptionType: String?
  public var exceptionSubtype: String?
  public var terminationReason: String?
  public var terminationNamespace: String?
  public var terminationCode: String?
  /// Application-specific information (the payload `asi` text), when present.
  public var applicationSpecificInformation: String?

  /// Whether the report indicates a watchdog/resource-limit termination rather
  /// than a normal application crash. Uses the jetsam bug-type codes and any
  /// jetsam/resource termination namespace. A plain `SIGNAL`/exc crash (e.g.
  /// bug type 309, an uncaught Swift fatal error) is not classified as one.
  public var impliesWatchdogOrResourceTermination: Bool {
    if let namespace = terminationNamespace {
      let normalized = namespace.lowercased()
      if normalized.contains("jetsam")
        || normalized.contains("resource")
        || normalized.contains("memory")
        || normalized.contains("cpu")
        || normalized.contains("diskwrite")
      {
        return true
      }
    }
    guard let bugType, !bugType.isEmpty else { return false }
    let normalized = bugType.lowercased()
    if normalized.contains("jetsam") || normalized.contains("resource") {
      return true
    }
    // Jetson / memory-resource bug report codes.
    let resourceCodes = ["298", "98", "327", "385"]
    return resourceCodes.contains(bugType)
  }

  /// A one-screen human-readable summary aimed at the crash-diagnosis loop:
  /// process, termination namespace/code/reason, exception, and any
  /// application-specific detail. Values are concatenated only when present.
  public func summary() -> String {
    var lines: [String] = []
    let heading = name ?? filename ?? "crash report"
    lines.append(heading)
    lines.append(String(repeating: "-", count: heading.count))

    if let terminationNamespace {
      var line = "Termination: \(terminationNamespace)"
      if let code = terminationCode, !code.isEmpty { line += " (\(code))" }
      if let reason = terminationReason, !reason.isEmpty { line += " — \(reason)" }
      lines.append(line)
    }
    if impliesWatchdogOrResourceTermination {
      lines.append("Classified: watchdog / resource-limit termination (jetsam/CPU/diskwrites).")
    }
    if let exceptionType {
      var line = "Exception: \(exceptionType)"
      if let subtype = exceptionSubtype, !subtype.isEmpty { line += " — \(subtype)" }
      lines.append(line)
    }
    if let asi = applicationSpecificInformation, !asi.isEmpty {
      lines.append("App specific: \(asi)")
    }
    if let bugType, lines.count <= 2 {
      lines.append("Bug type: \(bugType)")
    }
    return lines.joined(separator: "\n")
  }

  /// A short verdict used as the trailing status line by `device crash`.
  public var verdict: String {
    guard impliesWatchdogOrResourceTermination else {
      if let exceptionType { return "application crash (\(exceptionType))" }
      return "crash report (no termination pattern detected)"
    }
    let code =
      "\(terminationNamespace ?? "resource")\(terminationReason.map { " \($0)" } ?? "")"
    return "terminated by \(code)"
  }
}