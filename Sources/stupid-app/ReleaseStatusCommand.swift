import ASCKit
import ArgumentParser
import Foundation
import ProjectCore

/// `stupid-app release status`: reports the recorded and, optionally, live App Store
/// Connect state of the last release for the current project.
struct ReleaseStatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Report the state of the last release."
  )

  @Flag(
    name: .customLong("live"),
    help:
      "Query App Store Connect for the current build processing and beta state instead of only the recorded manifest."
  )
  var live = false

  @Option(name: .customLong("home"), help: "Credential store directory.")
  var home: String?

  @Option(name: .customLong("output"), help: "Release directory (defaults to ./.release).")
  var output: String?

  mutating func run() async throws {
    let projectRoot = URL(fileURLWithPath: ".")
    let outputDir = URL(
      fileURLWithPath: output ?? projectRoot.appendingPathComponent(".release").path)
    let manifestURL = outputDir.appendingPathComponent("release-manifest.json")
    guard let data = try? Data(contentsOf: manifestURL) else {
      throw ReleaseStatusError.noManifest(manifestURL.path)
    }
    guard let manifest = try? JSONDecoder().decode(ReleaseManifest.self, from: data) else {
      throw ReleaseStatusError.invalidManifest(manifestURL.path)
    }

    print("Last release (\(manifestURL.path)):")
    print("  bundle ID:   \(manifest.appBundleId)")
    print("  version:     \(manifest.marketingVersion) (\(manifest.buildNumber))")
    print("  IPA:         \(manifest.ipaPath)")
    print("  IPA SHA-256: \(manifest.ipaSha256)")
    print("  build upload: \(manifest.buildUploadId)")
    if let buildID = manifest.buildId {
      print("  build:       \(buildID)")
    }
    if let state = manifest.uploadState {
      print("  upload:      \(state)")
    }
    if let state = manifest.processingState {
      print("  processing:  \(state)")
    }
    if let state = manifest.internalBetaState {
      print("  internal beta: \(state)")
    }
    if let state = manifest.externalBetaState {
      print("  external beta: \(state)")
    }

    guard live else { return }

    guard let buildID = manifest.buildId else {
      throw ReleaseStatusError.noBuildID(manifest.buildUploadId)
    }
    let context = try ASCContext.resolve(home: home, purpose: "release status")
    let operations = context.operations()

    let build = try operations.getBuild(id: buildID)
    print("Live App Store Connect state:")
    print("  build:       \(build.id)")
    print("  processing:  \(build.processingState ?? "unknown")")
    let beta = try operations.getBuildBetaDetail(buildID: buildID)
    print("  internal beta: \(beta.internalBuildState ?? "unknown")")
    print("  external beta: \(beta.externalBuildState ?? "unknown")")
  }
}

enum ReleaseStatusError: Error, CustomStringConvertible {
  case noManifest(String)
  case invalidManifest(String)
  case noBuildID(String)

  var description: String {
    switch self {
    case .noManifest(let path):
      return
        "No release manifest found at '\(path)'. Run `stupid-app release upload` first or pass --output."
    case .invalidManifest(let path):
      return
        "The release manifest at '\(path)' could not be decoded. Re-run `stupid-app release upload`."
    case .noBuildID(let buildUploadID):
      return
        "The last upload (\(buildUploadID)) did not resolve to a build, so live state is unavailable. Run `stupid-app release upload --wait`."
    }
  }
}
