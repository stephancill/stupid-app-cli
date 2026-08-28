import Foundation

/// Bumps the `CFBundleVersion` (and optionally marketing version) in one or more
/// `Info.plist` files in lockstep so the app and every bundled extension share the same
/// build. Performs targeted text replacement to preserve existing plist formatting.
public enum ReleaseBumper {
  public enum Error: Swift.Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case versionMissing(String)
    case invalidVersion(string: String, path: String)
    case writeFailed(String)

    public var description: String {
      switch self {
      case let .unreadable(path):
        return "Could not read plist at '\(path)'."
      case let .versionMissing(path):
        return "No CFBundleVersion found at '\(path)'."
      case let .invalidVersion(string, path):
        return "CFBundleVersion '\(string)' at '\(path)' is not a decimal integer."
      case let .writeFailed(path):
        return "Could not write bumped build number to '\(path)'."
      }
    }
  }

  /// Returns the current `CFBundleVersion` from a plist at `url`.
  public static func currentBuildNumber(at url: URL) throws -> Int {
    guard let data = try? Data(contentsOf: url) else {
      throw Error.unreadable(url.path)
    }
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
      as? [String: Any]
    else {
      throw Error.unreadable(url.path)
    }
    guard let value = plist["CFBundleVersion"] as? String else {
      throw Error.versionMissing(url.path)
    }
    guard let parsed = Int(value) else {
      throw Error.invalidVersion(string: value, path: url.path)
    }
    return parsed
  }

  /// Returns the current `CFBundleVersion` from a plist at `url`.
  @discardableResult
  public static func bumpBuildNumber(inFileAt url: URL, to newValue: Int) throws -> Int {
    let previous = try currentBuildNumber(at: url)
    try replaceStringValue("<string>\(newValue)</string>", forKey: "CFBundleVersion", at: url)
    return previous
  }

  // MARK: - Non-integer build numbers

  /// Reads the current string value of a key (used for build numbers and marketing
  /// versions whose text may not be a plain decimal integer).
  public static func currentVersionString(forKey key: String, in url: URL) throws -> String {
    guard let text = try? String(contentsOf: url, encoding: .utf8),
      let value = Self.stringValue(afterKey: key, in: text)
    else {
      throw Error.versionMissing(url.path)
    }
    return value
  }

  /// Computes the next build number for a value that is either a decimal integer
  /// (`42`) or a dotted numeric build (`1.12.3`). The last numeric component is
  /// incremented; a trailing non-numeric component appends `.1`. Returns nil when the
  /// value carries no numeric component to bump.
  public static func nextBuildNumber(_ value: String) -> String? {
    let components = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard let lastIndex = components.indices.last else { return nil }
    if let last = Int(components[lastIndex].trimmingCharacters(in: .whitespaces)) {
      var next = components
      next[lastIndex] = String(last + 1)
      return next.joined(separator: ".")
    }
    // No integer at the end: append ".1" to a numeric prefix, else fail.
    let prefix = components.dropLast().joined(separator: ".")
    let prefixValid = prefix.isEmpty || prefix.split(separator: ".").allSatisfy {
      Int($0) != nil
    }
    return prefixValid ? prefix + ".1" : nil
  }

  /// Bumps the build number in place to its next value, preserving formatting. Returns
  /// the new value.
  @discardableResult
  public static func bumpBuildVersion(inFileAt url: URL) throws -> String {
    let current = try currentVersionString(forKey: "CFBundleVersion", in: url)
    guard let next = nextBuildNumber(current) else {
      throw Error.invalidVersion(string: current, path: url.path)
    }
    try replaceStringValue("<string>\(next)</string>", forKey: "CFBundleVersion", at: url)
    return next
  }

  /// Bumps the patch (last) component of the marketing version in place. Returns the
  /// new marketing version.
  @discardableResult
  public static func bumpMarketingVersion(inFileAt url: URL) throws -> String {
    let current = try currentVersionString(forKey: "CFBundleShortVersionString", in: url)
    guard let next = nextBuildNumber(current) else {
      throw Error.invalidVersion(string: current, path: url.path)
    }
    try replaceStringValue("<string>\(next)</string>", forKey: "CFBundleShortVersionString", at: url)
    return next
  }

  // MARK: - Shared plist text editing

  /// Locates the `<string>…</string>` immediately following a matched `<key>K</key>` and
  /// returns its contents, preserving the rest.
  static func stringValue(afterKey key: String, in text: String) -> String? {
    let keyTag = "<key>\(key)</key>"
    guard let keyRange = text.range(of: keyTag) else { return nil }
    let pattern = #"<string>([^<]*)</string>"#
    let afterKey = text[keyRange.upperBound...]
    guard let valueRange = afterKey.range(of: pattern, options: .regularExpression) else {
      return nil
    }
    return String(afterKey[valueRange]).replacingOccurrences(
      of: pattern, with: "$1", options: .regularExpression)
  }

  /// Replaces the first `<string>…</string>` after a given key while preserving
  /// surrounding formatting.
  static func replaceStringValue(_ replacement: String, forKey key: String, at url: URL) throws {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      throw Error.unreadable(url.path)
    }
    let markerTag = "<key>\(key)</key>"
    guard let keyRange = text.range(of: markerTag) else {
      throw Error.versionMissing(url.path)
    }
    let pattern = #"<string>[^<]*</string>"#
    let afterKey = text[keyRange.upperBound...]
    guard let valueRange = afterKey.range(of: pattern, options: .regularExpression) else {
      throw Error.versionMissing(url.path)
    }
    let updated =
      text[..<valueRange.lowerBound] + replacement + text[valueRange.upperBound...]
    do {
      try updated.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      throw Error.writeFailed(url.path)
    }
  }
}