import Foundation
import Testing

@testable import SigningKit

struct NativeCodeResourcesTests {
  @Test("writes and independently verifies shallow bundle resources")
  func writesAndVerifiesResources() throws {
    let fixture = try makeBundle()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let data = try NativeCodeResources.write(appBundle: fixture, executableName: "Fixture")
    try NativeCodeResources.verify(
      appBundle: fixture, executableName: "Fixture", data: data)

    try Data("changed".utf8).write(to: fixture.appendingPathComponent("Assets.car"))
    #expect(throws: NativeCodeResources.Error.resourceMismatch("Assets.car")) {
      try NativeCodeResources.verify(
        appBundle: fixture, executableName: "Fixture", data: data)
    }
  }

  @Test("detects added resources and escaping symlinks")
  func rejectsUnsealedAndUnsafeResources() throws {
    let fixture = try makeBundle()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let data = try NativeCodeResources.write(appBundle: fixture, executableName: "Fixture")
    try Data("added".utf8).write(to: fixture.appendingPathComponent("Added.txt"))
    #expect(throws: NativeCodeResources.Error.self) {
      try NativeCodeResources.verify(
        appBundle: fixture, executableName: "Fixture", data: data)
    }

    try FileManager.default.createSymbolicLink(
      atPath: fixture.appendingPathComponent("Escape").path, withDestinationPath: "/tmp")
    #expect(throws: NativeCodeResources.Error.self) {
      try NativeCodeResources.write(appBundle: fixture, executableName: "Fixture")
    }
  }

  @Test("uses Apple's no-Resources rule set for flat iOS bundles")
  func writesFlatBundleRules() throws {
    let fixture = try makeBundle(includeResourcesDirectory: false)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let data = try NativeCodeResources.write(appBundle: fixture, executableName: "Fixture")
    let plist = try #require(
      PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        as? [String: Any])
    let rules = try #require(plist["rules"] as? [String: Any])
    #expect(rules["^.*"] as? Bool == true)
    try NativeCodeResources.verify(appBundle: fixture, executableName: "Fixture", data: data)
  }

  @Test("deep signing excludes nested signature internals but seals appex CodeResources")
  func deepSealExcludesNestedSignatureInternals() throws {
    let fixture = try makeDeepBundle()
    defer { try? FileManager.default.removeItem(at: fixture) }

    let data = try NativeCodeResources.write(
      appBundle: fixture, executableName: "Fixture", deep: true)
    let plist = try #require(
      PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        as? [String: Any])
    let rules2 = try #require(plist["rules2"] as? [String: Any])
    // Deep mode must not emit `nested: true` rules, which would conflict with the
    // containing app sealing the appex bundles per-file.
    #expect(hasNestedRule(rules2) == false)

    let files2 = try #require(plist["files2"] as? [String: Any])
    // The appex's own CodeResources resource seal is sealed by the containing app...
    #expect(files2["PlugIns/TestExt.appex/_CodeSignature/CodeResources"] != nil)
    // ...but its CodeDirectory/CodeSignature/CodeRequirements are not.
    #expect(files2["PlugIns/TestExt.appex/_CodeSignature/CodeDirectory"] == nil)
    #expect(files2["PlugIns/TestExt.appex/_CodeSignature/CodeSignature"] == nil)
    #expect(files2["PlugIns/TestExt.appex/_CodeSignature/CodeRequirements"] == nil)
    // Normal appex resource files are still sealed.
    #expect(files2["PlugIns/TestExt.appex/Info.plist"] != nil)

    try NativeCodeResources.verify(
      appBundle: fixture, executableName: "Fixture", data: data, deep: true)
  }

  private func hasNestedRule(_ rules: [String: Any]) -> Bool {
    rules.values.contains { value in
      guard let dict = value as? [String: Any] else { return false }
      return dict["nested"] as? Bool == true
    }
  }

  private func makeDeepBundle() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("native-deep-\(UUID().uuidString).app", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("app-plist".utf8).write(to: root.appendingPathComponent("Info.plist"))
    try Data("app-exec".utf8).write(to: root.appendingPathComponent("Fixture"))

    let appex = root.appendingPathComponent("PlugIns/TestExt.appex", isDirectory: true)
    try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
    try Data("ext-plist".utf8).write(to: appex.appendingPathComponent("Info.plist"))
    try Data("ext-exec".utf8).write(to: appex.appendingPathComponent("TestExt"))
    let sigDir = appex.appendingPathComponent("_CodeSignature", isDirectory: true)
    try FileManager.default.createDirectory(at: sigDir, withIntermediateDirectories: true)
    try Data("sig-code-directory".utf8).write(to: sigDir.appendingPathComponent("CodeDirectory"))
    try Data("sig-code-signature".utf8).write(to: sigDir.appendingPathComponent("CodeSignature"))
    try Data("sig-code-requirements".utf8).write(to: sigDir.appendingPathComponent("CodeRequirements"))
    try Data("sig-code-resources".utf8).write(to: sigDir.appendingPathComponent("CodeResources"))
    return root
  }

  private func makeBundle(includeResourcesDirectory: Bool = true) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("native-resources-\(UUID().uuidString).app", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("plist".utf8).write(to: root.appendingPathComponent("Info.plist"))
    try Data("executable".utf8).write(to: root.appendingPathComponent("Fixture"))
    try Data("asset".utf8).write(to: root.appendingPathComponent("Assets.car"))
    try Data("profile".utf8).write(to: root.appendingPathComponent("embedded.mobileprovision"))
    if includeResourcesDirectory {
      let resources = root.appendingPathComponent("Resources", isDirectory: true)
      try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
      try Data("value".utf8).write(to: resources.appendingPathComponent("value.txt"))
    }
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("AssetLink").path,
      withDestinationPath: "Assets.car")
    return root
  }
}
