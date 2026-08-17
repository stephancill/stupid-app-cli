import Foundation

public enum NativeAppClassifier {
  public struct Plan: Equatable, Sendable {
    public let appBundle: URL
    public let executableURL: URL
    public let executableName: String
    public let bundleIdentifier: String
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
    let root = appBundle.standardizedFileURL
    guard root.pathExtension == "app" else { throw Error.malformed("input is not an .app bundle") }
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
    for name in unsupportedRoots
    where FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
      throw Error.unsupported("nested signable directory '\(name)' is present")
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
      if values.isDirectory == true,
        url.pathExtension == "app" || url.pathExtension == "appex"
          || url.pathExtension == "framework"
      {
        throw Error.unsupported("nested signable bundle '\(relative)' is present")
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
