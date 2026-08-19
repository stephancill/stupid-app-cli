import Foundation
import Testing

@testable import SigningKit

struct NativeAppClassifierTests {
  @Test("shallow mode rejects a nested appex bundle")
  func shallowRejectsNestedBundle() throws {
    let fixture = try makeDeepBundle()
    defer { try? FileManager.default.removeItem(at: fixture) }
    #expect(throws: NativeAppClassifier.Error.self) {
      _ = try NativeAppClassifier.classify(appBundle: fixture, mode: .shallow)
    }
  }

  @Test("deep mode permits a nested appex bundle and reports the app identity")
  func deepAcceptsNestedBundle() throws {
    let fixture = try makeDeepBundle()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let plan = try NativeAppClassifier.classify(appBundle: fixture, mode: .deep)
    #expect(plan.bundleIdentifier == "com.example.Deep")
    #expect(plan.executableName == "Deep")
  }

  private func makeDeepBundle() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("classifier-deep-\(UUID().uuidString).app", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("<dict/>".utf8).write(to: root.appendingPathComponent("Info.plist"))
    try Data("exec".utf8).write(to: root.appendingPathComponent("Deep"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("Deep").path)

    let appex = root.appendingPathComponent("PlugIns/TestExt.appex", isDirectory: true)
    try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
    try Data("<dict/>".utf8).write(to: appex.appendingPathComponent("Info.plist"))
    try Data("ext-exec".utf8).write(to: appex.appendingPathComponent("TestExt"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: appex.appendingPathComponent("TestExt").path)

    // Write a bundle identifier into the app Info.plist so classification is deterministic.
    let info: [String: Any] = [
      "CFBundleExecutable": "Deep",
      "CFBundleIdentifier": "com.example.Deep",
      "CFBundlePackageType": "APPL",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: root.appendingPathComponent("Info.plist"))
    return root
  }
}
