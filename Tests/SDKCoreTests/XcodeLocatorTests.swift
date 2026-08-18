import Foundation
import Testing

@testable import SDKCore

/// Hermetic tests for the `xcode-select`-equivalent developer-directory resolution and
/// in-place Xcode installation detection. No real Xcode is required.
struct XcodeLocatorTests {
  /// Builds a fake Xcode-app layout under a temp root with an iPhoneOS SDK, toolchain
  /// executables, and the metadata files the locator reads.
  private func fakeXcodeApp(
    root: URL,
    appName: String = "Xcode.app",
    version: String = "26.1.1",
    build: String = "17B100",
    sdkVersion: String = "26.1"
  ) throws -> URL {
    let app = root.appendingPathComponent(appName, isDirectory: true)
    let dev = app.appendingPathComponent("Contents/Developer", isDirectory: true)
    let sdk = dev
      .appendingPathComponent(
        "Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk", isDirectory: true)
    try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
    let boot = dev
      .appendingPathComponent(
        "Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk",
        isDirectory: true)
    try FileManager.default.createDirectory(at: boot, withIntermediateDirectories: true)
    let bin = dev.appendingPathComponent(
      "Toolchains/XcodeDefault.xctoolchain/usr/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: bin.appendingPathComponent("swift"))
    try Data("#!/bin/sh\n".utf8).write(to: bin.appendingPathComponent("swiftc"))
    let features = [FileAttributeKey.posixPermissions: 0o755]
    try FileManager.default.setAttributes(features, ofItemAtPath: bin.appendingPathComponent("swift").path)
    try FileManager.default.setAttributes(features, ofItemAtPath: bin.appendingPathComponent("swiftc").path)

    let sdkSettings: [String: Any] = ["Version": sdkVersion, "CanonicalName": "iphoneos\(sdkVersion)"]
    let settings = try JSONSerialization.data(withJSONObject: sdkSettings)
    try settings.write(to: sdk.appendingPathComponent("SDKSettings.json"))

    let versionPlist: [String: Any] = [
      "CFBundleShortVersionString": version,
      "ProductBuildVersion": build,
    ]
    let plist = try PropertyListSerialization.data(fromPropertyList: versionPlist, format: .xml, options: 0)
    try FileManager.default.createDirectory(
      at: app.appendingPathComponent("Contents", isDirectory: true), withIntermediateDirectories: true)
    try plist.write(to: app.appendingPathComponent("Contents/version.plist"))
    return app
  }

  @Test("DEVELOPER_DIR points the developer directory")
  func developerDirEnvironment() throws {
    let root = try testRoot()
    defer { cleanup(root) }
    let app = try fakeXcodeApp(root: root)
    let dev = app.appendingPathComponent("Contents/Developer", isDirectory: true)

    let resolved = XcodeLocator.resolvedDeveloperDirectory(
      candidates: .init(
        environmentDeveloperDir: dev.path,
        selectionSymlink: root.appendingPathComponent("missing-link"),
        selectionFile: root.appendingPathComponent("missing-file"),
        applicationDirectory: root))
    #expect(resolved == dev)
  }

  @Test("DEVELOPER_DIR pointing at the app is normalized")
  func developerDirAppPath() throws {
    let root = try testRoot()
    defer { cleanup(root) }
    let app = try fakeXcodeApp(root: root)

    let resolved = XcodeLocator.resolvedDeveloperDirectory(
      candidates: .init(
        environmentDeveloperDir: app.path,
        selectionSymlink: root.appendingPathComponent("missing-link"),
        selectionFile: root.appendingPathComponent("missing-file"),
        applicationDirectory: root))
    expectPath(
      resolved, equals: app.appendingPathComponent("Contents/Developer", isDirectory: true),
      relativeTo: root)
  }

  @Test("selection symlink wins over the default application directory")
  func selectionSymlink() throws {
    let root = try testRoot()
    defer { cleanup(root) }
    _ = try fakeXcodeApp(root: root, appName: "Xcode.app", version: "15.0")
    let selected = try fakeXcodeApp(root: root, appName: "Selected.app", version: "26.1.1")
    let link = root.appendingPathComponent("xcode_select_link")
    try FileManager.default.createSymbolicLink(
      atPath: link.path,
      withDestinationPath: selected.appendingPathComponent("Contents/Developer").path)

    let resolved = XcodeLocator.resolvedDeveloperDirectory(
      candidates: .init(
        environmentDeveloperDir: nil,
        selectionSymlink: link,
        selectionFile: root.appendingPathComponent("missing-file"),
        applicationDirectory: root))
    expectPath(
      resolved, equals: selected.appendingPathComponent("Contents/Developer", isDirectory: true),
      relativeTo: root)
  }

  @Test("default Xcode.app wins without any selection state")
  func defaultApp() throws {
    let root = try testRoot()
    defer { cleanup(root) }
    let app = try fakeXcodeApp(root: root)

    let resolved = XcodeLocator.resolvedDeveloperDirectory(
      candidates: .init(
        environmentDeveloperDir: nil,
        selectionSymlink: root.appendingPathComponent("missing-link"),
        selectionFile: root.appendingPathComponent("missing-file"),
        applicationDirectory: root))
    expectPath(
      resolved, equals: app.appendingPathComponent("Contents/Developer", isDirectory: true),
      relativeTo: root)
  }

  @Test("no Xcode app resolves to nil (imported-bundle mode)")
  func noXcode() throws {
    let root = try testRoot()
    defer { cleanup(root) }

    let resolved = XcodeLocator.resolvedDeveloperDirectory(
      candidates: .init(
        environmentDeveloperDir: nil,
        selectionSymlink: root.appendingPathComponent("missing-link"),
        selectionFile: root.appendingPathComponent("missing-file"),
        applicationDirectory: root))
    #expect(resolved == nil)
  }

  @Test("an app without an iPhoneOS SDK is not a usable installation")
  func missingIPhoneOSSDK() throws {
    let root = try testRoot()
    defer { cleanup(root) }
    let app = root.appendingPathComponent("Xcode.app", isDirectory: true)
    // Only the developer directory exists; no iPhoneOS SDK.
    try FileManager.default.createDirectory(
      at: app.appendingPathComponent("Contents/Developer", isDirectory: true),
      withIntermediateDirectories: true)

    let resolved = XcodeLocator.resolvedDeveloperDirectory(
      candidates: .init(
        environmentDeveloperDir: nil,
        selectionSymlink: root.appendingPathComponent("missing-link"),
        selectionFile: root.appendingPathComponent("missing-file"),
        applicationDirectory: root))
    #expect(resolved == nil)
    #expect(XcodeLocator.installation(developerDirectory: root) == nil)
  }

  @Test("detection reads Xcode and SDK metadata and toolchain paths")
  func installationMetadata() throws {
    let root = try testRoot()
    defer { cleanup(root) }
    let app = try fakeXcodeApp(root: root)

    let installation = try #require(XcodeLocator.detect(
      candidates: .init(
        environmentDeveloperDir: nil,
        selectionSymlink: root.appendingPathComponent("missing-link"),
        selectionFile: root.appendingPathComponent("missing-file"),
        applicationDirectory: root)))

    let dev = app.appendingPathComponent("Contents/Developer", isDirectory: true)
    expectPath(installation.appURL, equals: app, relativeTo: root)
    expectPath(installation.developerDirectory, equals: dev, relativeTo: root)
    #expect(installation.version == "26.1.1")
    #expect(installation.build == "17B100")
    #expect(installation.iphoneosSDKVersion == "26.1")
    #expect(
      installation.iphoneOSSDKURL.path.hasSuffix(
        "Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"))
    #expect(
      installation.iphoneSimulatorSDKURL?.path.hasSuffix(
        "Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk") == true)
    #expect(
      installation.toolchainSwiftURL.path.hasSuffix(
        "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"))
    #expect(
      installation.toolchainBinDirectory.path.hasSuffix(
        "Toolchains/XcodeDefault.xctoolchain/usr/bin"))
  }

  @Test("host SDK mode selection prefers Xcode in place and falls back to the bundle")
  func hostSDKModeSelection() throws {
    let root = try testRoot()
    defer { cleanup(root) }
    let candidates = XcodeLocator.Candidates(
      environmentDeveloperDir: nil,
      selectionSymlink: root.appendingPathComponent("missing-link"),
      selectionFile: root.appendingPathComponent("missing-file"),
      applicationDirectory: root)

    #expect(HostSDKMode.detect(candidates: candidates) == .importedBundle)

    _ = try fakeXcodeApp(root: root)
    let mode = HostSDKMode.detect(candidates: candidates)
    guard case let .xcodeInPlace(installation) = mode else {
      Issue.record("expected xcodeInPlace mode")
      return
    }
    #expect(installation.iphoneosSDKVersion == "26.1")
  }

  private func testRoot() throws -> URL {
    let directory = URL(fileURLWithPath: FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true).path)
      .standardizedFileURL
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Compares the tail of a resolved path against a root-relative expectation so
  /// assertions stay agnostic to Foundation's `/var` vs `/private/var`
  /// canonicalization.
  private func expectPath(_ resolved: URL?, equals expected: URL, relativeTo root: URL) {
    let relative = String(expected.path.dropFirst(root.path.count))
    #expect(resolved?.path.hasSuffix(relative) == true)
  }

  private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}