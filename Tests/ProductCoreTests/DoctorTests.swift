import Foundation
import Testing

@testable import ProductCore

struct DoctorTests {
  @Test("missing required tools fail without exposing credential contents")
  func missingTools() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let credentials = root.appendingPathComponent("credentials")
    try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: credentials.path)
    let secretValue = "PRIVATE-CREDENTIAL-VALUE"
    for name in ["asc.key.pem", "asc.key-id", "asc.issuer-id", "developer-team-id"] {
      let file = credentials.appendingPathComponent(name)
      try secretValue.write(to: file, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    let results = Doctor.run(
      input: .init(
        projectRoot: root,
        credentialHome: credentials,
        sdkID: "missing-sdk",
        swiftPath: root.appendingPathComponent("missing-swift").path,
        pythonPath: root.appendingPathComponent("missing-python").path,
        pymobiledevice3Path: root.appendingPathComponent("missing-pymobiledevice3").path
      ))

    #expect(results.contains { $0.name == "Swift toolchain" && $0.status == .failure })
    #expect(results.contains { $0.name == "iOS Swift SDK" && $0.status == .failure })
    #expect(results.contains { $0.name == "Native signing trust" && $0.status == .pass })
    #expect(results.contains { $0.name == "CoreDevice environment" && $0.status == .failure })
    #expect(results.contains { $0.name == "USB installer" && $0.status == .failure })
    #expect(results.contains { $0.name == "App Store Connect credentials" && $0.status == .pass })
    #expect(!results.map(\.detail).joined().contains(secretValue))
  }

  @Test("credential permission defects fail loudly")
  func credentialPermissions() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let credentials = root.appendingPathComponent("credentials")
    try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: credentials.path)
    for name in ["asc.key.pem", "asc.key-id", "asc.issuer-id", "developer-team-id"] {
      let file = credentials.appendingPathComponent(name)
      try Data("secret".utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    let results = Doctor.run(
      input: .init(
        projectRoot: root,
        credentialHome: credentials,
        swiftPath: root.appendingPathComponent("missing").path,
        pythonPath: root.appendingPathComponent("missing").path,
        pymobiledevice3Path: root.appendingPathComponent("missing").path
      ))

    let credential = try #require(results.first { $0.name == "App Store Connect credentials" })
    #expect(credential.status == .failure)
    #expect(credential.detail.contains("mode 0700"))
  }

  @Test("valid project configuration is reported without requiring credentials")
  func validProject() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    version: 1
    product: ExampleApp
    bundleID: net.example.app
    deploymentTarget: "17.0"
    infoPath: Info.plist
    """.write(to: root.appendingPathComponent("stupid-app.yml"), atomically: true, encoding: .utf8)
    try "// swift-tools-version: 6.2\n".write(
      to: root.appendingPathComponent("Package.swift"),
      atomically: true,
      encoding: .utf8
    )
    try Data().write(to: root.appendingPathComponent("Info.plist"))

    let results = Doctor.run(
      input: .init(
        projectRoot: root,
        credentialHome: root.appendingPathComponent("credentials"),
        swiftPath: root.appendingPathComponent("missing").path,
        pythonPath: root.appendingPathComponent("missing").path,
        pymobiledevice3Path: root.appendingPathComponent("missing").path
      ))

    let project = try #require(results.first { $0.name == "Project configuration" })
    #expect(project.status == .pass)
    #expect(project.detail.contains("ExampleApp"))
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
