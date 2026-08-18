import Foundation
import SDKCore
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
        hostSDKMode: .importedBundle
      ))

    #expect(results.contains { $0.name == "Swift toolchain" && $0.status == .failure })
    #expect(results.contains { $0.name == "iOS Swift SDK" && $0.status == .failure })
    #expect(results.contains { $0.name == "Host SDK mode" && $0.status == .pass })
    #expect(results.contains { $0.name == "Native signing trust" && $0.status == .pass })
    #expect(results.contains { $0.name == "Native CoreDevice TLS" && $0.status == .pass })
    #expect(results.contains { $0.name == "CoreDevice helper" && $0.status == .pass })
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
        hostSDKMode: .importedBundle
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
        hostSDKMode: .importedBundle
      ))

    let project = try #require(results.first { $0.name == "Project configuration" })
    #expect(project.status == .pass)
    #expect(project.detail.contains("ExampleApp"))
  }

  @Test("Xcode in place reports the in-place iPhoneOS SDK and toolchain")
  func xcodeInPlace() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let dev = root.appendingPathComponent("Xcode.app/Contents/Developer", isDirectory: true)
    let sdkDir = dev.appendingPathComponent(
      "Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk", isDirectory: true)
    try FileManager.default.createDirectory(at: sdkDir, withIntermediateDirectories: true)
    let toolchainBin = dev.appendingPathComponent(
      "Toolchains/XcodeDefault.xctoolchain/usr/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: toolchainBin, withIntermediateDirectories: true)
    for tool in ["swift", "swiftc"] {
      try Data("#! /bin/sh\n".utf8).write(to: toolchainBin.appendingPathComponent(tool))
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: toolchainBin.appendingPathComponent(tool).path)
    }

    let installation = XcodeInstallation(
      appURL: root.appendingPathComponent("Xcode.app"),
      developerDirectory: dev,
      iphoneOSSDKURL: sdkDir,
      iphoneSimulatorSDKURL: nil,
      toolchainSwiftURL: toolchainBin.appendingPathComponent("swift"),
      toolchainSwiftcURL: toolchainBin.appendingPathComponent("swiftc"),
      toolchainBinDirectory: toolchainBin,
      version: "26.1.1",
      build: "17B100",
      iphoneosSDKVersion: "26.1"
    )

    let results = Doctor.run(
      input: .init(
        projectRoot: root,
        credentialHome: root.appendingPathComponent("credentials"),
        hostSDKMode: .xcodeInPlace(installation)
      ))

    let mode = try #require(results.first { $0.name == "Host SDK mode" })
    #expect(mode.status == .pass)
    #expect(mode.detail.contains("Xcode SDK in place"))
    #expect(mode.detail.contains("Xcode 26.1.1"))
    let sdk = try #require(results.first { $0.name == "iOS Swift SDK" })
    #expect(
      sdk.detail.contains(
        "Xcode SDK in place provides iPhoneOS SDK 26.1 without an artifact bundle"))
  }

  #if os(macOS)
    @Test("macOS reports the built-in usbmuxd socket and the utun privilege boundary")
    func macOSDeviceChecks() throws {
      let root = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: root) }

      let results = Doctor.run(
        input: .init(
          projectRoot: root,
          credentialHome: root.appendingPathComponent("credentials"),
          hostSDKMode: .importedBundle
        ))

      let usbmuxd = try #require(results.first { $0.name == "usbmuxd socket" })
      #expect(usbmuxd.status == .pass)
      #expect(usbmuxd.detail.contains("/var/run/usbmuxd"))
      let utun = try #require(results.first { $0.name == "CoreDevice tunnel device" })
      #expect(utun.status == .pass)
      #expect(utun.detail.contains("utun"))
      #expect(utun.detail.contains("--sudo"))
    }
  #endif

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
