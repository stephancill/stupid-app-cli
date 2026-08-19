import Foundation
import Testing

@testable import SigningKit

struct EntitlementDeriverTests {
  private func writePlist(_ dict: [String: Any], to url: URL) throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: dict, format: .xml, options: 0)
    try data.write(to: url)
  }

  @Test("app groups are supported and reconciled an app-group subset")
  func appGroupsSupported() throws {
    let tmps = FileManager.default.temporaryDirectory
      .appendingPathComponent("deriver-groups-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmps, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmps) }

    let source = tmps.appendingPathComponent("App.entitlements")
    try writePlist([
      "com.apple.security.application-groups": ["group.net.stupidtech.widgets"]
    ], to: source)

    let profile = MobileProvisionParser.ProvisioningProfile(plist: [
      "Entitlements": [
        "com.apple.security.application-groups": ["group.net.stupidtech.widgets"],
        "application-identifier": "TEAM123.net.stupidtech.widgets",
        "com.apple.developer.team-identifier": "TEAM123",
        "get-task-allow": false,
      ]
    ])

    let derived = try EntitlementDeriver.derive(
      sourceURL: source,
      configuration: .distribution,
      bundleID: "net.stupidtech.widgets",
      profile: profile,
      teamID: "TEAM123"
    )
    #expect((derived["com.apple.security.application-groups"] as? [String]) == ["group.net.stupidtech.widgets"])
    #expect(derived["get-task-allow"] as? Bool == false)
  }

  @Test("app groups fail loudly when the profile does not authorize them")
  func appGroupsNotAuthorized() throws {
    let tmps = FileManager.default.temporaryDirectory
      .appendingPathComponent("deriver-groups-missing-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmps, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmps) }

    let source = tmps.appendingPathComponent("App.entitlements")
    try writePlist([
      "com.apple.security.application-groups": ["group.net.stupidtech.widgets"]
    ], to: source)

    // Profile authorizes no app groups -> loud failure, the manual-portal gate.
    let profile = MobileProvisionParser.ProvisioningProfile(plist: [
      "Entitlements": [
        "application-identifier": "TEAM123.net.stupidtech.widgets",
        "com.apple.developer.team-identifier": "TEAM123",
        "get-task-allow": false,
      ]
    ])

    #expect(throws: EntitlementDeriver.Error.notAuthorizedByProfile(
      "com.apple.security.application-groups")) {
      _ = try EntitlementDeriver.derive(
        sourceURL: source,
        configuration: .distribution,
        bundleID: "net.stupidtech.widgets",
        profile: profile,
        teamID: "TEAM123"
      )
    }
  }
}
