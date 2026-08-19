import Foundation

public enum NativeAppClassifier {
  public struct Plan: Equatable, Sendable {
    public let appBundle: URL
    public let executableURL: URL
    public let executableName: String
    public let bundleIdentifier: String
  }

  /// How strictly to treat nested signable bundles.
  public enum Mode: Equatable, Sendable {
    /// Reject any nested signable bundle or nested signable directory. Used by the
    /// single shallow app and by individual extension leaves.
    case shallow
    /// Permit nested signable bundles under `PlugIns/`/`Frameworks/` and nested
    /// signable directories. Used for the containing app in a multi-bundle build.
    case deep
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)

    public var description: String {
      switch self {
      case .malformed(let detail): return "Malformed native signing app: \(detail)."
      case .unsupported(let detail): return "Unsupported native signing app: \(detail)."
      }
    }
  }

  public static func classify(appBundle: URL) throws -> Plan {
    try classify(appBundle: appBundle, mode: .shallow)
  }

  public static func classify(appBundle: URL, mode: Mode) throws -> Plan {
    let root = appBundle.standardizedFileURL
    guard root.pathExtension == "app" || root.pathExtension == "appex" else {
      throw Error.malformed("input is not an .app/.appex bundle")
    }
    let infoURL = root.appendingPathComponent("Info.plist")
    guard let infoData = try? Data(contentsOf: infoURL),
      let info = try? PropertyListSerialization.propertyList(
        from: infoData, options: [], format: nil) as? [String: Any],
      let executableName = info["CFBundleExecutable"] as? String,
      let bundleIdentifier = info["CFBundleIdentifier"] as? String,
      !executableName.isEmpty, !bundleIdentifier.isEmpty,
      !executableName.contains("/"), !bundleIdentifier.contains("\0")
    else {
      throw Error.malformed("Info.plist lacks a valid CFBundleExecutable or CFBundleIdentifier")
    }
    let executableURL = root.appendingPathComponent(executableName)
    let executableValues = try executableURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey,
    ])
    let infoValues = try infoURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard executableValues.isRegularFile == true, executableValues.isSymbolicLink != true,
      infoValues.isRegularFile == true, infoValues.isSymbolicLink != true,
      FileManager.default.isExecutableFile(atPath: executableURL.path)
    else {
      throw Error.malformed("CFBundleExecutable is missing or not executable")
    }

    let unsupportedRoots = [
      "Frameworks", "SharedFrameworks", "PlugIns", "Plug-ins", "XPCServices", "Helpers",
    ]
    if mode == .shallow {
      for name in unsupportedRoots
      where FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
        throw Error.unsupported("nested signable directory '\(name)' is present")
      }
    }
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [
          .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        ],
        options: [],
        errorHandler: { _, _ in false })
    else { throw Error.malformed("bundle cannot be enumerated") }
    while let url = enumerator.nextObject() as? URL {
      let relative = String(url.path.dropFirst(root.path.count + 1))
      if relative == "_CodeSignature" {
        enumerator.skipDescendants()
        continue
      }
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
      ])
      let isNestedBundle =
        values.isDirectory == true
        && (url.pathExtension == "app" || url.pathExtension == "appex"
          || url.pathExtension == "framework")
      if isNestedBundle {
        // Nested signable bundles are sealed (not individually hashed) by the outer
        // app's CodeResources; they must be signed separately as leaves first. In
        // deep mode we permit them and let their CodeDirectory be sealed.
        if mode == .shallow {
          throw Error.unsupported("nested signable bundle '\(relative)' is present")
        }
        enumerator.skipDescendants()
        continue
      }
      if values.isRegularFile == true {
        if ["dylib", "so"].contains(url.pathExtension.lowercased()) {
          throw Error.unsupported("dynamic library '\(relative)' is present")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let executableBits = ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111
        if executableBits != 0, url.standardizedFileURL != executableURL.standardizedFileURL {
          throw Error.unsupported("additional executable file '\(relative)' is present")
        }
      }
    }
    return Plan(
      appBundle: root, executableURL: executableURL, executableName: executableName,
      bundleIdentifier: bundleIdentifier)
  }
}
