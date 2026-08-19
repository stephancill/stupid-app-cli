import ASCKit
import ArgumentParser
import Foundation
import ProjectCore

/// `stupid-app release new-build`: suggests the next integer build number for the current
/// project by querying App Store Connect for the most recently uploaded build and adding 1.
struct ReleaseNewBuildCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "new-build",
    abstract: "Suggest the next build number from the latest uploaded App Store Connect build."
  )

  @Option(name: .customLong("home"), help: "Credential store directory.")
  var home: String?

  @Option(
    name: .customLong("bundle-id"), help: "Override the bundle ID from stupid-app.yml.")
  var bundleID: String?

  @Option(
    name: .customLong("build-number"),
    help: "Explicit base build number to increment (default: latest uploaded build).")
  var explicitBase: String?

  mutating func run() async throws {
    let context = try ASCContext.resolve(home: home, purpose: "release new-build")
    let operations = context.operations()

    let bundleID = try resolveBundleID(explicit: bundleID)

    let base: Int
    if let explicitBase {
      guard let parsed = Int(explicitBase), parsed >= 0 else {
        throw ReleaseNewBuildError.invalidBase(explicitBase)
      }
      base = parsed
    } else {
      guard let appID = try operations.findApp(bundleID: bundleID) else {
        throw ReleaseNewBuildError.appNotFound(bundleID)
      }
      guard let latest = try operations.latestBuildNumber(appID: appID) else {
        print("1")
        return
      }
      guard let parsed = Int(latest) else {
        throw ReleaseNewBuildError.nonNumericLatest(latest)
      }
      base = parsed
    }

    print("\(base + 1)")
    FileHandle.standardError.write(
      Data(
        ("Next build number for '\(bundleID)': \(base + 1). Set CFBundleVersion to this before `stupid-app release upload`.\n")
          .utf8))
  }

  private func resolveBundleID(explicit: String?) throws -> String {
    if let explicit { return explicit }
    let configURL = URL(fileURLWithPath: "stupid-app.yml")
    guard let data = try? Data(contentsOf: configURL) else {
      throw ReleaseNewBuildError.configMissing
    }
    let config = try AppConfig.decode(data)
    return config.bundleID
  }
}

enum ReleaseNewBuildError: Error, CustomStringConvertible {
  case configMissing
  case appNotFound(String)
  case invalidBase(String)
  case nonNumericLatest(String)

  var description: String {
    switch self {
    case .configMissing:
      return
        "No stupid-app.yml found and no --bundle-id provided. Run from a project directory or pass --bundle-id."
    case .appNotFound(let bundleID):
      return "No App Store Connect app record found for bundle ID '\(bundleID)'."
    case .invalidBase(let value):
      return "'\(value)' is not a valid build number; use a non-negative decimal integer."
    case .nonNumericLatest(let value):
      return
        "The latest uploaded build number '\(value)' is not a decimal integer; pass --build-number explicitly."
    }
  }
}
