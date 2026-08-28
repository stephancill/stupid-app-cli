import Foundation
import ProjectCore
import Testing

@testable import ProjectCore

struct ReleasePreflightTests {
  private func writePlist(
    at dir: URL, name: String, marketing: String, build: String,
    compliance: Bool? = false
  ) throws -> URL {
    let url = dir.appendingPathComponent(name)
    var dict: [String: Any] = [
      "CFBundleShortVersionString": marketing,
      "CFBundleVersion": build,
    ]
    if let compliance {
      dict["ITSAppUsesNonExemptEncryption"] = compliance
    }
    let data = try PropertyListSerialization.data(
      fromPropertyList: dict, format: .xml, options: 0)
    try data.write(to: url)
    return url
  }

  private func config(
    infoPath: String = "App-Info.plist",
    extensions: [AppConfig.ExtensionConfig] = []
  ) -> AppConfig {
    AppConfig(
      version: 1, product: "App", bundleID: "net.example.app", deploymentTarget: "17.0",
      infoPath: infoPath, extensions: extensions.isEmpty ? nil : extensions)
  }

  @Test("ready when app and extension versions match and compliance is declared")
  func ready() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try writePlist(at: dir, name: "App-Info.plist", marketing: "1.2.0", build: "42", compliance: false)
    try writePlist(at: dir, name: "Ext-Info.plist", marketing: "1.2.0", build: "42", compliance: nil)

    let config = config(extensions: [
      AppConfig.ExtensionConfig(
        product: "Widget", bundleID: "net.example.app.widget", infoPath: "Ext-Info.plist")
    ])
    let assessment = ReleasePreflight.assess(config: config, projectRoot: dir)
    #expect(assessment.isReady)
    #expect(assessment.issues.isEmpty)
    #expect(assessment.appVersion == ReleasePreflight.VersionPair(marketing: "1.2.0", build: "42"))
  }

  @Test("flags marketing-version drift between the app and an extension")
  func marketingDrift() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try writePlist(at: dir, name: "App-Info.plist", marketing: "1.2.0", build: "42", compliance: false)
    try writePlist(at: dir, name: "Ext-Info.plist", marketing: "1.1.0", build: "42", compliance: nil)

    let config = config(extensions: [
      AppConfig.ExtensionConfig(
        product: "Widget", bundleID: "net.example.app.widget", infoPath: "Ext-Info.plist")
    ])
    let assessment = ReleasePreflight.assess(config: config, projectRoot: dir)
    #expect(!assessment.isReady)
    #expect(assessment.issues.contains { $0.contains("marketing version '1.1.0'") })
  }

  @Test("flags build drift between the app and an extension")
  func buildDrift() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try writePlist(at: dir, name: "App-Info.plist", marketing: "1.2.0", build: "42", compliance: false)
    try writePlist(at: dir, name: "Ext-Info.plist", marketing: "1.2.0", build: "41", compliance: nil)

    let config = config(extensions: [
      AppConfig.ExtensionConfig(
        product: "Widget", bundleID: "net.example.app.widget", infoPath: "Ext-Info.plist")
    ])
    let assessment = ReleasePreflight.assess(config: config, projectRoot: dir)
    #expect(!assessment.isReady)
    #expect(assessment.issues.contains { $0.contains("build '41'") })
  }

  @Test("flags a missing export-compliance declaration")
  func missingCompliance() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // No ITSAppUsesNonExemptEncryption key.
    try writePlist(at: dir, name: "App-Info.plist", marketing: "1.2.0", build: "42", compliance: nil)
    let config = config()
    let assessment = ReleasePreflight.assess(config: config, projectRoot: dir)
    #expect(!assessment.isReady)
    #expect(assessment.issues.contains { $0.contains("ITSAppUsesNonExemptEncryption") })
  }

  @Test("flags a declared true (exempt encryption) declaration")
  func trueComplianceFlagged() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try writePlist(at: dir, name: "App-Info.plist", marketing: "1.2.0", build: "42", compliance: true)
    let config = config()
    let assessment = ReleasePreflight.assess(config: config, projectRoot: dir)
    #expect(!assessment.isReady)
    #expect(assessment.issues.contains { $0.contains("ITSAppUsesNonExemptEncryption=true") })
  }
}