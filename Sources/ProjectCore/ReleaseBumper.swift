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

  /// Bumps `CFBundleVersion` in place to `newValue`, preserving the original plist
  /// formatting where possible. Returns the previous value.
  @discardableResult
  public static func bumpBuildNumber(inFileAt url: URL, to newValue: Int) throws -> Int {
    let previous = try currentBuildNumber(at: url)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      throw Error.unreadable(url.path)
    }
    // Find `<key>CFBundleVersion</key>` and replace the `<string>N</string>` that
    // immediately follows it, preserving surrounding whitespace/formatting.
    let key = "<key>CFBundleVersion</key>"
    guard let keyRange = text.range(of: key) else {
      throw Error.versionMissing(url.path)
    }
    let valuePattern = #"<string>\d+</string>"#
    let afterKey = text[keyRange.upperBound...]
    guard let valueRange = afterKey.range(of: valuePattern, options: .regularExpression)
    else {
      throw Error.versionMissing(url.path)
    }
    let replacement =
      text[..<valueRange.lowerBound] + "<string>\(newValue)</string>"
      + text[valueRange.upperBound...]
    do {
      try replacement.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      throw Error.writeFailed(url.path)
    }
    return previous
  }
}