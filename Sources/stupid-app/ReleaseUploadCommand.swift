import ASCKit
import ArgumentParser
import BuildCore
import Foundation
import ProjectCore
import SDKCore
import SigningKit

/// `stupid-app release upload`: uploads a distribution-signed IPA to App Store
/// Connect using the public Build Upload resources, resolves the exact build, and
/// optionally waits for processing and internal TestFlight readiness.
struct ReleaseUploadCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "upload",
    abstract: "Upload a distribution IPA to App Store Connect."
  )

  @Flag(
    name: .customLong("wait"), help: "Poll until the build is internally beta-ready on TestFlight.")
  var wait = false

  @Option(name: .customLong("ipa"), help: "Path to the IPA (defaults to ./.release/<product>.ipa).")
  var ipaPath: String?

  @Option(
    name: .customLong("app-bundle-id"),
    help: "Override the bundle ID used to resolve the App Store Connect app.")
  var appBundleIDOverride: String?

  @Option(name: .customLong("home"), help: "Credential store directory.")
  var home: String?

  @Option(name: .customLong("output"), help: "Release directory (defaults to ./.release).")
  var output: String?

  @Option(
    name: .customLong("poll-interval"), help: "Seconds between polls while waiting (default 20).")
  var pollInterval: Double = 20

  @Option(
    name: .customLong("sdk-id"),
    help: "Imported Swift SDK identifier used for provenance reporting.")
  var sdkID: String = "stupid-app-ios"

  @Option(name: .customLong("swift"), help: "Path to the host `swift` executable.")
  var swiftPath: String = "swift"

  mutating func run() async throws {
    let homeURL = URL(
      fileURLWithPath: home
        ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".stupid-app/credentials").path)
    let store = CredentialStore(home: homeURL)

    let configURL = URL(fileURLWithPath: "stupid-app.yml")
    guard let data = try? Data(contentsOf: configURL) else {
      throw ProjectError.unreadableConfig(configURL.path)
    }
    let config = try AppConfig.decode(data)
    let projectRoot = URL(fileURLWithPath: ".")
    let outputDir = URL(
      fileURLWithPath: output ?? projectRoot.appendingPathComponent(".release").path)

    // 1. Locate the IPA and read the exact versions that were packaged.
    let ipaURL = try locateIPA(config: config, outputDir: outputDir)
    let versions = try readPackagedVersions(config: config, product: config.product)

    // 2. Load the App Store Connect key and resolve the app record by bundle ID.
    let apiKey = try store.loadASCKey()
    let client = ASCClient(jwt: {
      try ASCJWTGenerator(key: apiKey).generate()
    })
    let operations = ASCOperations(client: client)
    let bundleID = appBundleIDOverride ?? config.bundleID
    guard let appID = try operations.findApp(bundleID: bundleID) else {
      throw ReleaseUploadError.appRecordNotFound(bundleID)
    }
    print("Resolved app record \(appID) for \(bundleID)")

    // 3. Reject a build number that has already been uploaded.
    if let existing = try operations.findBuild(
      appID: appID,
      version: versions.marketing,
      buildNumber: versions.build
    ) {
      throw ReleaseUploadError.buildNumberAlreadyUploaded(
        versions.build, existing.id, alreadyUploaded: true)
    }

    // 4. Upload, optionally waiting for TestFlight readiness.
    let uploader = BuildUploader(
      operations: operations,
      logger: { print($0) }
    )
    let timeouts = BuildUploader.Timeouts(pollInterval: pollInterval)
    let result: BuildUploader.Result
    do {
      result = try uploader.upload(
        ipaURL: ipaURL,
        appID: appID,
        version: versions.marketing,
        buildNumber: versions.build,
        wait: wait,
        timeouts: timeouts
      )
    } catch ASCError.http(let status, _) where status == 409 {
      // App Store Connect rejects a build number that already exists or is being
      // processed. This is a recoverable, already-uploaded state, not a packaging bug.
      let existing = try? operations.findBuild(
        appID: appID, version: versions.marketing, buildNumber: versions.build)
      if let existing {
        throw ReleaseUploadError.buildNumberAlreadyUploaded(
          versions.build, existing.id, alreadyUploaded: true)
      }
      throw ASCError.http(status, "a build " + (existing?.id ?? "with this number") + " is already being uploaded or processed")
    }

    // 5. Write the release manifest.
    let manifest = ReleaseManifest(
        appBundleId: bundleID,
        marketingVersion: versions.marketing,
        buildNumber: versions.build,
        ipaPath: relativePath(ipaURL, from: projectRoot) ?? ipaURL.path,
        ipaSha256: try SHA256.file(at: ipaURL),
        buildUploadId: result.buildUploadID,
        buildId: result.buildID,
        uploadState: result.uploadState,
        processingState: result.processingState,
        internalBetaState: result.internalBetaState,
        externalBetaState: result.externalBetaState,
        toolVersion: nil,
        signerVersion: NativeSigner.engineVersion,
        sdkVersion: try? SDKVersion.resolve(
            sdkID: sdkID, targetTriple: "arm64-apple-ios", swiftPath: swiftPath),
        compilerVersion: try? HostInfo.compilerVersion(swiftPath: swiftPath),
        extensions: config.extensions?.map {
            ReleaseManifest.ExtensionRecord(bundleId: $0.bundleID, product: $0.product)
        }
    )
    let manifestURL = outputDir.appendingPathComponent("release-manifest.json")
    try manifest.write(to: manifestURL)
    print("Wrote \(manifestURL.path)")

    print("Upload complete: Build Upload \(result.buildUploadID), file \(result.buildUploadFileID)")
    if wait {
      print(
        "Build \(result.buildID ?? "?") state: processing=\(result.processingState ?? "?") internal=\(result.internalBetaState ?? "?")"
      )
    }
  }

  private func locateIPA(config: AppConfig, outputDir: URL) throws -> URL {
    if let ipaPath {
      let url = URL(fileURLWithPath: ipaPath)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw ReleaseUploadError.ipaMissing(url.path)
      }
      return url
    }
    let url = outputDir.appendingPathComponent("\(config.product).ipa")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw ReleaseUploadError.ipaMissing(url.path)
    }
    return url
  }

  /// Reads CFBundleShortVersionString and CFBundleVersion from the packaged app's
  /// merged Info.plist (falling back to the source Info.plist).
  private func readPackagedVersions(config: AppConfig, product: String) throws -> (
    marketing: String, build: String
  ) {
    let candidates = [
      projectRoot.appendingPathComponent(
        ".build/arm64-apple-ios/release/\(product).app/Info.plist"),
      URL(fileURLWithPath: config.infoPath),
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
      if let values = try? readVersionValues(at: url) {
        return values
      }
    }
    throw ReleaseUploadError.versionInfoMissing(config.infoPath)
  }

  private var projectRoot: URL { URL(fileURLWithPath: ".") }

  private func readVersionValues(at url: URL) throws -> (marketing: String, build: String)? {
    guard let data = try? Data(contentsOf: url),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else {
      return nil
    }
    guard let marketing = plist["CFBundleShortVersionString"] as? String,
      let build = plist["CFBundleVersion"] as? String
    else {
      return nil
    }
    return (marketing, build)
  }

  private func relativePath(_ url: URL, from root: URL) -> String? {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard url.path.hasPrefix(rootPath) else { return nil }
    return String(url.path.dropFirst(rootPath.count))
  }
}

enum ReleaseUploadError: Error, CustomStringConvertible {
  case ipaMissing(String)
  case appRecordNotFound(String)
  case buildNumberAlreadyUploaded(String, String, alreadyUploaded: Bool)
  case versionInfoMissing(String)

  var description: String {
    switch self {
    case .ipaMissing(let path):
      return "No IPA found at '\(path)'. Run `stupid-app release archive` first or pass --ipa."
    case .appRecordNotFound(let bundleID):
      return
        "No App Store Connect app record exists for '\(bundleID)'. Create the app record in App Store Connect first (the API cannot create app records)."
    case .buildNumberAlreadyUploaded(let build, let id, alreadyUploaded: true):
      return
        "Build number \(build) already exists on App Store Connect (build \(id)). This is likely from an earlier upload of the same build that finished before this run. Run `stupid-app release status --live` to confirm the state instead of re-uploading; only bump CFBundleVersion if you genuinely need a new build."
    case .buildNumberAlreadyUploaded(let build, let id, alreadyUploaded: false):
      return
        "Build number \(build) has already been uploaded (build \(id)). Increment CFBundleVersion in Info.plist before re-uploading."
    case .versionInfoMissing(let path):
      return
        "Could not read CFBundleShortVersionString/CFBundleVersion from '\(path)'. Ensure the Info.plist declares both."
    }
  }
}
