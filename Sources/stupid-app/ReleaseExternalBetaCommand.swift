import ASCKit
import ArgumentParser
import Foundation
import ProjectCore

/// `stupid-app release external-beta`: makes a resolved build externally testable by
/// adding it to an external beta group, creating an external beta review submission, and
/// polling until external `IN_BETA_TESTING`. Updates the release manifest with the
/// submission and group ids.
struct ReleaseExternalBetaCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "external-beta",
    abstract: "Submit a build for external TestFlight and wait for external testing."
  )

  @Option(name: .customLong("build-id"), help: "App Store Connect build id (default: last release's build in the manifest).")
  var buildID: String?

  @Option(name: .customLong("group"), help: "Existing external beta group id (default: resolve by name).")
  var betaGroupID: String?

  @Option(
    name: .customLong("group-name"),
    help: "External beta group name to resolve or create (default: External Testers).")
  var betaGroupName: String = "External Testers"

  @Option(name: .customLong("whats-new"), help: "Set the per-build 'What to Test' note before submitting.")
  var whatsNew: String?

  @Option(name: .customLong("home"), help: "Credential store directory.")
  var home: String?

  @Option(name: .customLong("output"), help: "Release directory (defaults to ./.release).")
  var output: String?

  @Option(name: .customLong("poll-interval"), help: "Seconds between polls (default 20).")
  var pollInterval: Double = 20

  @Flag(name: .customLong("no-wait"), help: "Create the external review submission and exit; do not poll to external readiness.")
  var noWait = false

  mutating func run() async throws {
    let context = try ASCContext.resolve(home: home, purpose: "release external-beta")
    let operations = context.operations()

    let projectRoot = URL(fileURLWithPath: ".")
    let configURL = projectRoot.appendingPathComponent("stupid-app.yml")
    guard let data = try? Data(contentsOf: configURL) else {
      throw ReleaseExternalBetaError.missingConfig
    }
    let config = try AppConfig.decode(data)

    guard let appID = try operations.findApp(bundleID: config.bundleID) else {
      throw ReleaseExternalBetaError.appNotFound(config.bundleID)
    }
    let buildID = try resolveBuildID(operations: operations, appID: appID, config: config)

    // Resolve the external beta group: use the provided id or find/create by name.
    let group: ASCBetaGroup
    if let betaGroupID {
      group = ASCBetaGroup(id: betaGroupID, name: betaGroupName)
    } else if let found = try operations.findBetaGroup(appID: appID, name: betaGroupName) {
      group = found
    } else {
      group = try operations.createBetaGroup(name: betaGroupName, appID: appID, isInternalGroup: false)
      print("Created external beta group \(betaGroupName) (\(group.id))")
    }
    print("External beta group: \(group.id) (\(group.name))")

    // Ensure the build is in the group.
    try operations.addBuild(betaGroupID: group.id, buildID: buildID)
    print("Added build \(buildID) to beta group \(group.id)")

    if let whatsNew {
      _ = try operations.setWhatsNew(buildID: buildID, whatsNew: whatsNew)
      print("Set 'What to Test' on build \(buildID)")
    }

    // Skip submission when the build is already externally active.
    let detail = try operations.getBuildBetaDetail(buildID: buildID)
    if detail.externalBuildState == "IN_BETA_TESTING" {
      print("Build \(buildID) is already externally testable.")
      try recordManifest(buildID: buildID, groupID: group.id, submissionID: nil, externalState: detail.externalBuildState)
      return
    }

    // Create the external beta review submission.
    let submissionID = try operations.createBetaAppReviewSubmission(buildID: buildID, betaGroupID: group.id)
    print("Created external beta review submission \(submissionID)")

    guard !noWait else {
      try recordManifest(buildID: buildID, groupID: group.id, submissionID: submissionID, externalState: detail.externalBuildState)
      return
    }

    try pollExternal(buildID: buildID, submissionID: submissionID, operations: operations)
    try recordManifest(buildID: buildID, groupID: group.id, submissionID: submissionID, externalState: "IN_BETA_TESTING")
  }

  // MARK: - Resolution and polling

  private func resolveBuildID(operations: ASCOperations, appID: String, config: AppConfig) throws -> String {
    if let buildID { return buildID }
    if let manifest = loadManifest(), let build = manifest.buildId {
      print("Using last release build \(build) from the release manifest")
      return build
    }
    let versions = readPackagedVersions(config: config)
    if let build = try operations.findBuild(
      appID: appID, version: versions.marketing, buildNumber: versions.build)
    {
      return build.id
    }
    throw ReleaseExternalBetaError.noBuild
  }

  private func pollExternal(buildID: String, submissionID: String, operations: ASCOperations) throws {
    // 1. Wait for review approval.
    let approvalDeadline = Date().addingTimeInterval(5 * 60)
    var approved = false
    while !approved {
      let submission = try operations.getBetaAppReviewSubmission(id: submissionID)
      switch ASCOperations.externalReviewDecision(submission.state) {
      case .approved:
        print("Beta review approved (state=\(submission.state ?? "?"))")
        approved = true
      case .rejected(let state):
        throw ReleaseExternalBetaError.reviewRejected(state)
      case .keepPolling:
        if Date() > approvalDeadline {
          throw ReleaseExternalBetaError.timedOut("external beta review approval for submission \(submissionID)")
        }
        Thread.sleep(forTimeInterval: pollInterval)
      }
    }

    // 2. Wait for external IN_BETA_TESTING.
    let externalDeadline = Date().addingTimeInterval(5 * 60)
    while true {
      let detail = try operations.getBuildBetaDetail(buildID: buildID)
      switch ASCOperations.externalBetaDecision(detail.externalBuildState) {
      case .ready:
        print("Build is externally testable (external=\(detail.externalBuildState ?? "?"))")
        return
      case .terminal(let state):
        throw ReleaseExternalBetaError.externalBetaFailed(state)
      case .keepPolling:
        if Date() > externalDeadline {
          throw ReleaseExternalBetaError.timedOut("external IN_BETA_TESTING for build \(buildID)")
        }
        Thread.sleep(forTimeInterval: pollInterval)
      }
    }
  }

  private func readPackagedVersions(config: AppConfig) -> (marketing: String, build: String) {
    let candidates = [
      URL(fileURLWithPath: ".build/arm64-apple-ios/release/\(config.product).app/Info.plist"),
      URL(fileURLWithPath: config.infoPath),
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
      if let values = ReleasePreflight.readVersions(at: url) {
        return (values.marketing, values.build)
      }
    }
    return ("0.0.0", "0")
  }

  private func loadManifest() -> ReleaseManifest? {
    let url = manifestURL()
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(ReleaseManifest.self, from: data)
  }

  private func recordManifest(buildID: String, groupID: String, submissionID: String?, externalState: String?) throws {
    let url = manifestURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    guard var manifest = try? JSONDecoder().decode(ReleaseManifest.self, from: Data(contentsOf: url)) else { return }
    manifest.betaSubmissionId = submissionID
    manifest.betaGroupId = groupID
    manifest.externalBetaState = externalState
    try manifest.write(to: url)
    print("Updated \(url.path)")
  }

  private func manifestURL() -> URL {
    let outputDir = URL(
      fileURLWithPath: output ?? URL(fileURLWithPath: ".").appendingPathComponent(".release").path)
    return outputDir.appendingPathComponent("release-manifest.json")
  }
}

enum ReleaseExternalBetaError: Error, CustomStringConvertible {
  case missingConfig
  case appNotFound(String)
  case noBuild
  case reviewRejected(String)
  case externalBetaFailed(String)
  case timedOut(String)

  var description: String {
    switch self {
    case .missingConfig:
      return "No stupid-app.yml found. Run from a project directory."
    case .appNotFound(let bundleID):
      return "No App Store Connect app record found for bundle ID '\(bundleID)'."
    case .noBuild:
      return "Could not resolve which build to submit. Pass --build-id or run `stupid-app release upload --wait` first."
    case .reviewRejected(let state):
      return "External beta review was rejected (state '\(state)'). Fix the build and resubmit."
    case .externalBetaFailed(let state):
      return "Build could not reach external TestFlight (external build state '\(state)'). Check export compliance and resolve violations."
    case .timedOut(let phase):
      return "Timed out while \(phase). Check the state in App Store Connect and re-run `stupid-app release external-beta --wait`."
    }
  }
}