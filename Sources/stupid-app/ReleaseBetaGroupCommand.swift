import ASCKit
import ArgumentParser
import Foundation
import ProjectCore

/// `stupid-app release beta-group`: manage external beta groups and their builds/testers.
struct ReleaseBetaGroupCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "beta-group",
    abstract: "List, create, and populate external beta groups.",
    subcommands: [List.self, Create.self, AddBuild.self, AddTester.self]
  )

  struct CommonOptions: ParsableArguments {
    @Option(name: .customLong("home"), help: "Credential store directory.")
    var home: String?

    @Option(name: .customLong("bundle-id"), help: "Override the bundle ID from stupid-app.yml.")
    var bundleID: String?

    @Option(name: .customLong("group"), help: "Beta group id.")
    var group: String?

    var defaultGroupName: String { "External Testers" }

    func build() throws -> (ASCOperations, String) {
      let context = try ASCContext.resolve(home: home, purpose: "release beta-group")
      let operations = context.operations()
      let configURL = URL(fileURLWithPath: "stupid-app.yml")
      guard let data = try? Data(contentsOf: configURL),
        let config = try? AppConfig.decode(data)
      else {
        throw BetaGroupError.configMissing
      }
      let bundleIDValue = bundleID ?? config.bundleID
      guard let appID = try operations.findApp(bundleID: bundleIDValue) else {
        throw BetaGroupError.appNotFound(bundleIDValue)
      }
      return (operations, appID)
    }

    func requireGroupID() throws -> String {
      guard let group else {
        throw BetaGroupError.groupRequired
      }
      return group
    }
  }

  struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List beta groups for the app.")
    @OptionGroup var common: CommonOptions
    mutating func run() async throws {
      let (operations, appID) = try common.build()
      let groups = try operations.listBetaGroups(appID: appID)
      for group in groups {
        let kind = (group.isInternalGroup ?? false) ? "internal" : "external"
        print("\(group.id)  [\(kind)]  \(group.name)")
      }
    }
  }

  struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create an external beta group.")
    @OptionGroup var common: CommonOptions
    @Option(name: .customLong("name"), help: "Beta group name.")
    var name: String?
    mutating func run() async throws {
      let (operations, appID) = try common.build()
      let groupName = name ?? common.defaultGroupName
      let group = try operations.createBetaGroup(name: groupName, appID: appID, isInternalGroup: false)
      print(group.id)
    }
  }

  struct AddBuild: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-build", abstract: "Add a build to a beta group.")
    @OptionGroup var common: CommonOptions
    @Option(name: .customLong("build-id"), help: "App Store Connect build id.")
    var buildID: String
    mutating func run() async throws {
      let (operations, _) = try common.build()
      let groupID = try common.requireGroupID()
      try operations.addBuild(betaGroupID: groupID, buildID: buildID)
      print("Added build \(buildID) to beta group \(groupID)")
    }
  }

  struct AddTester: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-tester", abstract: "Add a tester to a beta group.")
    @OptionGroup var common: CommonOptions
    @Option(name: .customLong("email"), help: "Tester email.")
    var email: String
    @Option(name: .customLong("first-name"), help: "Tester first name.")
    var firstName: String?
    @Option(name: .customLong("last-name"), help: "Tester last name.")
    var lastName: String?
    mutating func run() async throws {
      let (operations, appID) = try common.build()
      let groupID = try common.requireGroupID()
      let testerID = try operations.findBetaTester(appID: appID, email: email)?.id
        ?? operations.createBetaTester(email: email, firstName: firstName, lastName: lastName)
      try operations.addBetaTesters(betaGroupID: groupID, testerIDs: [testerID])
      print("Added tester \(email) to beta group \(groupID)")
    }
  }
}

/// `stupid-app release beta-notes`: set the "What to Test" note on a build.
struct ReleaseBetaNotesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "beta-notes",
    abstract: "Set the 'What to Test' note on a build."
  )

  @Option(name: .customLong("build-id"), help: "App Store Connect build id (default: manifest build).")
  var buildID: String?

  @Option(name: .customLong("whats-new"), help: "The 'What to Test' note to set.")
  var whatsNew: String

  @Option(name: .customLong("home"), help: "Credential store directory.")
  var home: String?

  @Option(name: .customLong("output"), help: "Release directory (defaults to ./.release).")
  var output: String?

  mutating func run() async throws {
    let context = try ASCContext.resolve(home: home, purpose: "release beta-notes")
    let operations = context.operations()
    guard let buildID = buildID ?? resolveManifestBuildID() else {
      throw ReleaseNotesError.noBuild
    }
    _ = try operations.setWhatsNew(buildID: buildID, whatsNew: whatsNew)
    print("Set 'What to Test' on build \(buildID)")
  }

  private func resolveManifestBuildID() -> String? {
    let outputDir = URL(
      fileURLWithPath: output ?? URL(fileURLWithPath: ".").appendingPathComponent(".release").path)
    let url = outputDir.appendingPathComponent("release-manifest.json")
    guard let data = try? Data(contentsOf: url),
      let manifest = try? JSONDecoder().decode(ReleaseManifest.self, from: data)
    else { return nil }
    return manifest.buildId
  }
}

enum BetaGroupError: Error, CustomStringConvertible {
  case configMissing
  case appNotFound(String)
  case groupRequired

  var description: String {
    switch self {
    case .configMissing:
      return "No stupid-app.yml found. Run from a project directory or pass --bundle-id."
    case .appNotFound(let bundleID):
      return "No App Store Connect app record found for bundle ID '\(bundleID)'."
    case .groupRequired:
      return "A beta group id is required. Provide --group."
    }
  }
}

enum ReleaseNotesError: Error, CustomStringConvertible {
  case noBuild

  var description: String {
    switch self {
    case .noBuild:
      return "Could not resolve a build to annotate. Pass --build-id or run `stupid-app release upload --wait` first."
    }
  }
}