import ArgumentParser
import Foundation
import ProjectCore

/// `stupid-app release bump`: increments (or sets) `CFBundleVersion` in `Info.plist` for
/// the app and every bundled extension in lockstep, so a release archive carries one
/// shared build number across all bundles. Prints the old and new values.
struct ReleaseBumpCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bump",
    abstract: "Bump CFBundleVersion across the app and every bundled extension in lockstep."
  )

  @Option(
    name: .customLong("build-number"),
    help: "Explicit build number to set; otherwise the current build is incremented by 1.")
  var buildNumber: Int?

  @Flag(
    name: .customLong("shallow"),
    help: "Only bump the app's Info.plist (skip bundled extensions).")
  var shallow = false

  @Flag(
    name: .customLong("marketing"),
    help: "Bump CFBundleShortVersionString instead of CFBundleVersion.")
  var marketing = false

  mutating func run() async throws {
    let configURL = URL(fileURLWithPath: "stupid-app.yml")
    guard let data = try? Data(contentsOf: configURL) else {
      throw ReleaseBumpError.configMissing
    }
    let config = try AppConfig.decode(data)

    var infoURLs = [URL(fileURLWithPath: config.infoPath)]
    if !shallow, let extensions = config.extensions {
      infoURLs += extensions.map { URL(fileURLWithPath: $0.infoPath) }
    }

    for url in infoURLs {
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw ReleaseBumpError.missingPlist(url.path)
      }
      if marketing {
        let current = try ReleaseBumper.currentVersionString(
          forKey: "CFBundleShortVersionString", in: url)
        let new = try ReleaseBumper.bumpMarketingVersion(inFileAt: url)
        print("\(url.path): \(current) -> \(new)")
      } else if let target = buildNumber {
        let old = try ReleaseBumper.bumpBuildNumber(inFileAt: url, to: target)
        print("\(url.path): \(old) -> \(target)")
      } else {
        let current = try ReleaseBumper.currentVersionString(
          forKey: "CFBundleVersion", in: url)
        let new = try ReleaseBumper.bumpBuildVersion(inFileAt: url)
        print("\(url.path): \(current) -> \(new)")
      }
    }
  }
}

enum ReleaseBumpError: Error, CustomStringConvertible {
  case configMissing
  case missingPlist(String)

  var description: String {
    switch self {
    case .configMissing:
      return
        "No stupid-app.yml found. Run from a project directory."
    case let .missingPlist(path):
      return "Info.plist not found at '\(path)'. Check infoPath in stupid-app.yml."
    }
  }
}