import ArgumentParser
import Foundation
import ProjectCore

/// `stupid-app release preflight`: hard-gates a release before anything is uploaded by
/// checking the version lockstep across the app and bundled extensions and the export
/// compliance declaration. Runs locally against the project (no App Store Connect call),
/// so it fails fast on the mistakes the API would otherwise reject only after upload.
struct ReleasePreflightCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "preflight",
    abstract: "Check release readiness locally before uploading (versions, extensions, export compliance)."
  )

  mutating func run() async throws {
    let projectRoot = URL(fileURLWithPath: ".")
    let configURL = projectRoot.appendingPathComponent("stupid-app.yml")
    guard let data = try? Data(contentsOf: configURL) else {
      throw ReleasePreflightError.missingConfig
    }
    let config = try AppConfig.decode(data)

    let assessment = ReleasePreflight.assess(config: config, projectRoot: projectRoot)

    print("Release preflight for \(config.bundleID):")
    if let app = assessment.appVersion {
      print("  app:      \(app.marketing) (\(app.build))")
    }
    for (bundleID, version) in assessment.extensions.sorted(by: { $0.key < $1.key }) {
      print("  ext:      \(bundleID)  \(version.marketing) (\(version.build))")
    }
    if assessment.issues.isEmpty {
      print("  status:   READY")
      return
    }
    print("  status:   NOT READY")
    for issue in assessment.issues {
      print("  - \(issue)")
    }
    throw ReleasePreflightError.blocked(assessment.issues)
  }
}

enum ReleasePreflightError: Error, CustomStringConvertible {
  case missingConfig
  case blocked([String])

  var description: String {
    switch self {
    case .missingConfig:
      return "No stupid-app.yml found. Run `stupid-app release preflight` from a project directory."
    case .blocked(let issues):
      return "Release preflight found \(issues.count) issue(s). Resolve them before `release archive`/`release upload`:"
        + issues.map { "\n- \($0)" }.joined()
    }
  }
}