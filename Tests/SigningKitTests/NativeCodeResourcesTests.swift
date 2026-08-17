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
