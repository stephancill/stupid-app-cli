import Crypto
import Foundation

public enum NativeCodeResources {
  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)
    case resourceMismatch(String)

    public var description: String {
      switch self {
      case .malformed(let detail):
        return "Malformed CodeResources: \(detail)."
      case .unsupported(let detail):
        return "Unsupported CodeResources input: \(detail)."
      case .resourceMismatch(let path):
        return "CodeResources verification failed for '\(path)'."
      }
    }
  }

  private enum Seal: Equatable {
    case hash(sha1: Data, sha256: Data)
    case symlink(String)
  }

  public static func write(appBundle: URL, executableName: String) throws -> Data {
    let appBundle = appBundle.standardizedFileURL.resolvingSymlinksInPath()
    let seals = try collectSeals(appBundle: appBundle, executableName: executableName)
    var resourcesIsDirectory: ObjCBool = false
    let hasResourcesDirectory =
      FileManager.default.fileExists(
        atPath: appBundle.appendingPathComponent("Resources").path,
        isDirectory: &resourcesIsDirectory) && resourcesIsDirectory.boolValue
    var files = [String: Any]()
    var files2 = [String: Any]()
    for (path, seal) in seals.sorted(by: { $0.key < $1.key }) {
      switch seal {
      case .hash(let sha1, let sha256):
        files[path] = sha1
        files2[path] = ["hash": sha1, "hash2": sha256]
      case .symlink(let target):
        files2[path] = ["symlink": target]
      }
    }
    let plist: [String: Any] = [
      "files": files,
      "files2": files2,
      "rules": legacyRules(hasResourcesDirectory: hasResourcesDirectory),
      "rules2": modernRules(hasResourcesDirectory: hasResourcesDirectory),
    ]
    let data: Data
    do {
      data = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
    } catch {
      throw Error.malformed("could not serialize the resource seal")
    }
    let signatureDirectory = appBundle.appendingPathComponent("_CodeSignature", isDirectory: true)
    try FileManager.default.createDirectory(
      at: signatureDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
    try data.write(
      to: signatureDirectory.appendingPathComponent("CodeResources"), options: .atomic)
    return data
  }

  public static func verify(appBundle: URL, executableName: String, data: Data) throws {
    let object: Any
    do {
      object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    } catch {
      throw Error.malformed("root plist is invalid")
    }
    guard let root = object as? [String: Any], let files = root["files"] as? [String: Any],
      let files2 = root["files2"] as? [String: Any], root["rules"] != nil,
      root["rules2"] != nil
    else {
      throw Error.malformed("required root dictionaries are missing")
    }
    let expected = try collectSeals(appBundle: appBundle, executableName: executableName)
    guard Set(files2.keys) == Set(expected.keys),
      Set(files.keys)
        == Set(
          expected.compactMap {
            if case .hash = $0.value { return $0.key }
            return nil
          })
    else {
      let missing = Set(expected.keys).subtracting(files2.keys).sorted().joined(separator: ",")
      let extra = Set(files2.keys).subtracting(expected.keys).sorted().joined(separator: ",")
      throw Error.resourceMismatch("resource path set (missing: \(missing); extra: \(extra))")
    }
    for (path, seal) in expected {
      guard let entry = files2[path] as? [String: Any] else {
        throw Error.malformed("files2 entry is not a dictionary")
      }
      switch seal {
      case .hash(let sha1, let sha256):
        guard entry.count == 2, entry["hash"] as? Data == sha1,
          entry["hash2"] as? Data == sha256, files[path] as? Data == sha1
        else {
          throw Error.resourceMismatch(path)
        }
      case .symlink(let target):
        guard entry.count == 1, entry["symlink"] as? String == target else {
          throw Error.resourceMismatch(path)
        }
      }
    }
  }

  private static func collectSeals(appBundle: URL, executableName: String) throws
    -> [String: Seal]
  {
    let root = appBundle.standardizedFileURL.resolvingSymlinksInPath()
    guard root.isFileURL, !executableName.isEmpty, !executableName.contains("/") else {
      throw Error.malformed("bundle or executable path is invalid")
    }
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
        options: [],
        errorHandler: { _, _ in false })
    else {
      throw Error.malformed("bundle cannot be enumerated")
    }
    var result = [String: Seal]()
    while let url = enumerator.nextObject() as? URL {
      let rootPath = canonicalTemporaryPath(root.path)
      let resourcePath = canonicalTemporaryPath(url.path)
      guard resourcePath.hasPrefix(rootPath + "/") else {
        throw Error.malformed("enumerated resource escaped the bundle")
      }
      let relative = String(resourcePath.dropFirst(rootPath.count + 1))
      if relative == "_CodeSignature" {
        enumerator.skipDescendants()
        continue
      }
      if relative == "Info.plist" || relative == executableName {
        continue
      }
      let values = try url.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      if values.isSymbolicLink == true {
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        try validateSymlink(target: target, at: url, root: root)
        result[relative] = .symlink(target.replacingOccurrences(of: "\\", with: "/"))
      } else if values.isRegularFile == true {
        let data = try Data(contentsOf: url)
        result[relative] = .hash(
          sha1: Data(Insecure.SHA1.hash(data: data)),
          sha256: Data(SHA256.hash(data: data)))
      } else if values.isDirectory != true {
        throw Error.unsupported("bundle contains a non-file resource")
      }
    }
    return result
  }

  private static func validateSymlink(target: String, at url: URL, root: URL) throws {
    guard !target.hasPrefix("/") else {
      throw Error.unsupported("bundle contains an absolute symlink")
    }
    let resolved = url.deletingLastPathComponent().appendingPathComponent(target)
      .standardizedFileURL
    let resolvedPath = canonicalTemporaryPath(resolved.path)
    let rootPath = canonicalTemporaryPath(root.path)
    guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") else {
      throw Error.unsupported("bundle contains an escaping symlink")
    }
  }

  private static func canonicalTemporaryPath(_ path: String) -> String {
    // macOS redirects /var and /tmp to /private; Foundation's directory
    // enumerator yields the /private form while resolvingSymlinksInPath()
    // leaves the input form, so canonicalize both sides before comparing.
    if path.hasPrefix("/var/") || path == "/var" {
      return "/private" + path
    }
    if path.hasPrefix("/tmp/") || path == "/tmp" {
      return "/private" + path
    }
    return path
  }

  private static func legacyRules(hasResourcesDirectory: Bool) -> [String: Any] {
    if !hasResourcesDirectory {
      return [
        "^.*": true,
        "^.*\\.lproj/": ["optional": true, "weight": 1000],
        "^.*\\.lproj/locversion.plist$": ["omit": true, "weight": 1100],
        "^Base\\.lproj/": ["weight": 1010],
        "^version.plist$": true,
      ]
    }
    return [
      "^Resources/": true,
      "^Resources/.*\\.lproj/": ["optional": true, "weight": 1000],
      "^Resources/Base\\.lproj/": ["weight": 1010],
      "^Resources/.*\\.lproj/locversion.plist$": ["omit": true, "weight": 1100],
      "^version.plist$": true,
    ]
  }

  private static func modernRules(hasResourcesDirectory: Bool) -> [String: Any] {
    if !hasResourcesDirectory {
      return [
        "^.*": true,
        ".*\\.dSYM($|/)": ["weight": 11],
        "^(.*/)?\\.DS_Store$": ["omit": true, "weight": 2000],
        "^.*\\.lproj/": ["optional": true, "weight": 1000],
        "^.*\\.lproj/locversion.plist$": ["omit": true, "weight": 1100],
        "^Base\\.lproj/": ["weight": 1010],
        "^Info\\.plist$": ["omit": true, "weight": 20],
        "^PkgInfo$": ["omit": true, "weight": 20],
        "^embedded\\.provisionprofile$": ["weight": 20],
        "^version\\.plist$": ["weight": 20],
      ]
    }
    return [
      "^.*": true,
      "^[^/]+$": ["nested": true, "weight": 10],
      "^(Frameworks|SharedFrameworks|PlugIns|Plug-ins|XPCServices|Helpers|MacOS|Library/(Automator|Spotlight|LoginItems))/":
        [
          "nested": true, "weight": 10,
        ],
      ".*\\.dSYM($|/)": ["weight": 11],
      "^(.*/)?\\.DS_Store$": ["omit": true, "weight": 2000],
      "^Info\\.plist$": ["omit": true, "weight": 20],
      "^PkgInfo$": ["omit": true, "weight": 20],
      "^Resources/": ["weight": 20],
      "^Resources/.*\\.lproj/": ["optional": true, "weight": 1000],
      "^Resources/Base\\.lproj/": ["weight": 1010],
      "^Resources/.*\\.lproj/locversion.plist$": ["omit": true, "weight": 1100],
      "^embedded\\.provisionprofile$": ["weight": 20],
      "^version\\.plist$": ["weight": 20],
    ]
  }
}
