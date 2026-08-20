import Foundation

/// Parses `.ips` crash-report buffers into a `CrashReport`.
///
/// The static behavior mirrors `pycrashreport`'s `get_crash_report_from_buf`:
/// the first line is parsed as metadata JSON; the rest of the buffer is parsed
/// as JSON when possible (user-mode and jetsam reports) and otherwise ignored
/// (legacy panic/binary text). All extraction is best-effort and defensive.
public enum CrashReportParsing {
  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case missingMetadataLine
    case invalidMetadata(String)

    public var description: String {
      switch self {
      case .empty:
        return "The crash report buffer is empty."
      case .missingMetadataLine:
        return "The crash report buffer is missing its metadata line."
      case .invalidMetadata(let detail):
        return "The crash report metadata is invalid: \(detail)."
      }
    }
  }

  /// Parses a crash report from raw `.ips` bytes (UTF-8) or a Swift string.
  public static func parse(_ buffer: String) throws -> CrashReport {
    let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw Error.empty }
    guard let newline = trimmed.range(of: "\n") else {
      throw Error.missingMetadataLine
    }

    let metadataText = String(trimmed[..<newline.lowerBound]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard !metadataText.isEmpty else { throw Error.missingMetadataLine }
    guard let metadata = parseJSON(metadataText) else {
      throw Error.invalidMetadata(metadataText)
    }

    var report = CrashReport()
    report.incidentID = metadata["incident_id"] as? String
    report.name = stringValue(metadata["name"])
    report.bugType = stringValue(metadata["bug_type"])
    report.appName = stringValue(metadata["app_name"])
    report.bundleID = stringValue(metadata["bundle_id"]) ?? stringValue(metadata["sender"])
    report.osVersion = stringValue(metadata["os_version"])
    report.timestamp = stringValue(metadata["timestamp"])

    let payload = String(trimmed[newline.upperBound...])
    applyJSONPayload(payload, into: &report)
    applyLegacyTextPayload(payload, into: &report)
    return report
  }

  private static func parseJSON(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    guard
      let object = try? JSONSerialization.jsonObject(with: data, options: []),
      let dict = object as? [String: Any]
    else { return nil }
    return dict
  }

  private static func stringValue(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let string = value as? String, !string.isEmpty { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

  private static func applyJSONPayload(_ payload: String, into report: inout CrashReport) {
    // Try the full payload first.
    if let json = parseJSON(payload) {
      extractJSON(json, into: &report)
      return
    }
    // Fall back to the spliced multi-object merge that pycrashreport handles
    // (a `\n  \n` separating a header JSON object from a trailing JSON root).
    if let marker = payload.range(of: "\n  \n") {
      let trailing = String(payload[marker.upperBound...])
      if let json = parseJSON(trailing), !json.isEmpty {
        extractJSON(json, into: &report)
      }
    }
  }

  private static func extractJSON(_ json: [String: Any], into report: inout CrashReport) {
    if let exception = json["exception"] as? [String: Any] {
      report.exceptionType = stringValue(exception["type"])
      report.exceptionSubtype = stringValue(exception["subtype"])
    }
    if let termination = json["termination"] as? [String: Any] {
      report.terminationNamespace = stringValue(termination["namespace"])
      report.terminationCode = stringValue(termination["code"])
      report.terminationReason =
        stringValue(termination["indicator"])
        ?? stringValue(termination["reason"])
        ?? stringValue(termination["reasons"])
    }
    if let asi = json["asi"] as? String {
      report.applicationSpecificInformation = asi
    } else if let asi = json["asi"] as? [String: Any],
      let message = asi["message"] as? String
    {
      report.applicationSpecificInformation = message
    }
  }

  /// Extracts key-value fields from the human-readable legacy payload emitted by
  /// `exc_resource` / `cpu_resource` / `jetsam` crash reports. That format (a
  /// `Date/Time:` + `Event:` + `Action taken:` header) carries the resource
  /// verdict that the JSON parse cannot see.
private static func applyLegacyTextPayload(_ payload: String, into report: inout CrashReport) {
    // Only attempt the fallback when the payload is not JSON.
    if parseJSON(payload) != nil {
      return
    }
    func value(after label: String) -> String? {
      guard let range = payload.range(of: label) else { return nil }
      let afterLabel = payload[range.upperBound...]
      guard let lineEnd = afterLabel.firstIndex(of: "\n") else {
        return String(afterLabel).trimmingCharacters(in: .whitespaces)
      }
      return String(afterLabel[..<lineEnd]).trimmingCharacters(in: .whitespaces)
    }

    // cpu_resource / memory_resource / jetsam reports carry `Event: <kind> usage`.
    if let event = value(after: "Event:") {
      report.terminationReason = event
      if report.terminationNamespace == nil {
        if event.contains("cpu") {
          report.terminationNamespace = "CPU_RESOURCE"
        } else if event.contains("memory") || event.contains("jetsam") {
          report.terminationNamespace = "MEMORY"
        }
      }
    }
    if value(after: "Action taken:") != nil, report.terminationNamespace == nil {
      report.terminationNamespace = "RESOURCE"
    }
  }
}