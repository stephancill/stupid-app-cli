import Foundation

/// Where a binary target's XCFramework comes from. A local one sits inside its package; a
/// remote one (`.binaryTarget(url:checksum:)`) is downloaded by SwiftPM into the build's
/// scratch directory, so it can only be read after the build resolved it.
public enum XCFrameworkLocation: Sendable, Equatable, Hashable {
  case local(URL)
  case remote(packageIdentity: String)
}

/// The library an XCFramework provides for one platform: a static archive, which SwiftPM
/// links into the executable, or a dynamic framework, which the bundle must embed and sign.
public struct XCFrameworkSlice: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case staticArchive
    case dynamicFramework
  }

  public var kind: Kind
  /// `<xcframework>/<LibraryIdentifier>/<LibraryPath>`.
  public var url: URL

  /// Selects the arm64 library for `platform`. Every library in the XCFramework must be the
  /// same kind, so a dependency never links statically on one platform and dynamically on
  /// another.
  public static func select(
    xcframework: URL, platform: TargetPlatform, targetName: String
  ) throws -> XCFrameworkSlice {
    let infoURL = xcframework.appendingPathComponent("Info.plist")
    guard
      let data = try? Data(contentsOf: infoURL),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let libraries = info["AvailableLibraries"] as? [[String: Any]], !libraries.isEmpty
    else {
      throw BuildError.unsupportedBinaryTarget(
        targetName, "\(xcframework.lastPathComponent)/Info.plist lists no AvailableLibraries")
    }
    var kinds = Set<String>()
    for library in libraries {
      let libraryPath = library["LibraryPath"] as? String ?? "<missing LibraryPath>"
      switch (libraryPath as NSString).pathExtension {
      case "a": kinds.insert("a")
      case "framework": kinds.insert("framework")
      default:
        throw BuildError.unsupportedBinaryTarget(
          targetName, "'\(libraryPath)' is neither a static archive (.a) nor a framework")
      }
    }
    guard kinds.count == 1, let kindName = kinds.first else {
      throw BuildError.unsupportedBinaryTarget(
        targetName, "it mixes static archives and frameworks across platforms")
    }
    let variant: String? = platform.isSimulator ? "simulator" : nil
    guard
      let library = libraries.first(where: { library in
        library["SupportedPlatform"] as? String == platform.tripleOS
          && library["SupportedPlatformVariant"] as? String == variant
          && (library["SupportedArchitectures"] as? [String])?.contains("arm64") == true
      }),
      let identifier = library["LibraryIdentifier"] as? String, !identifier.contains("/"),
      let libraryPath = library["LibraryPath"] as? String, !libraryPath.contains("/")
    else {
      throw BuildError.unsupportedBinaryTarget(
        targetName,
        "it has no arm64 \(platform.os.displayName)\(variant.map { " \($0)" } ?? "") library")
    }
    return XCFrameworkSlice(
      kind: kindName == "a" ? .staticArchive : .dynamicFramework,
      url: xcframework.appendingPathComponent(identifier, isDirectory: true)
        .appendingPathComponent(libraryPath))
  }

  /// The XCFramework SwiftPM downloaded for a remote binary target:
  /// `<scratch>/artifacts/<package identity>/<target>/<name>.xcframework`.
  public static func remoteArtifact(
    scratch: URL, packageIdentity: String, targetName: String
  ) throws -> URL {
    let directory = scratch.appendingPathComponent("artifacts", isDirectory: true)
      .appendingPathComponent(packageIdentity, isDirectory: true)
      .appendingPathComponent(targetName, isDirectory: true)
    let candidates =
      ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
      .filter { $0.hasSuffix(".xcframework") }
    guard candidates.count == 1 else {
      throw BuildError.unsupportedBinaryTarget(
        targetName,
        "SwiftPM left \(candidates.count) XCFrameworks for it in \(directory.path); expected exactly one"
      )
    }
    return directory.appendingPathComponent(candidates[0], isDirectory: true)
  }
}
