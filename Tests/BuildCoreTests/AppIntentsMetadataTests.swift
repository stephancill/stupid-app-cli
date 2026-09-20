import Foundation
import Testing

@testable import BuildCore

/// Tests for the App Intents metadata generator that runs after a SwiftPM build.
struct AppIntentsMetadataTests {
  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "app-intents-metadata-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @discardableResult
  private func writeConstValues(
    _ contents: String, binDirectory: URL, module: String, file: String
  ) throws -> URL {
    let moduleDirectory = binDirectory.appendingPathComponent(
      "\(module).build", isDirectory: true)
    try FileManager.default.createDirectory(at: moduleDirectory, withIntermediateDirectories: true)
    let url = moduleDirectory.appendingPathComponent("\(file).swiftconstvalues")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  @Test("detects an App Intent declaration in const-values")
  func detectsAppIntent() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeConstValues(
      """
      [{"typeName":"App.PingIntent","file":"/src/PingIntent.swift",
        "conformances":["AppIntents.AppIntent","Swift.Sendable"]}]
      """, binDirectory: root, module: "App", file: "PingIntent")

    let files = AppIntentsMetadata.constValueFiles(binDirectory: root, module: "App")
    #expect(files.count == 1)
    #expect(AppIntentsMetadata.declaresAppIntents(constValueFiles: files))
  }

  @Test("detects an App Shortcuts provider declaration in const-values")
  func detectsAppShortcutsProvider() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeConstValues(
      """
      [{"typeName":"App.Shortcuts","file":"/src/Shortcuts.swift",
        "conformances":["AppIntents.AppShortcutsProvider"]}]
      """, binDirectory: root, module: "App", file: "Shortcuts")

    let files = AppIntentsMetadata.constValueFiles(binDirectory: root, module: "App")
    #expect(AppIntentsMetadata.declaresAppIntents(constValueFiles: files))
  }

  @Test("ignores modules without App Intents declarations")
  func ignoresOrdinaryModule() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeConstValues(
      #"[{"typeName":"App.View","file":"/src/View.swift","conformances":["Swift.Sendable"]}]"#,
      binDirectory: root, module: "App", file: "View")

    let files = AppIntentsMetadata.constValueFiles(binDirectory: root, module: "App")
    #expect(!AppIntentsMetadata.declaresAppIntents(constValueFiles: files))
    let generated = try AppIntentsMetadata.generate(
      binDirectory: root, modules: ["App"], bundleDirectory: root, toolchain: nil)
    #expect(generated == false)
  }

  @Test("collects the source paths named by const-values")
  func collectsSourceFiles() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeConstValues(
      """
      [
        {"typeName":"App.A","file":"/src/A.swift","conformances":["AppIntents.AppIntent"]},
        {"typeName":"App.B","file":"/src/B.swift","conformances":["AppIntents.AppIntent"]},
        {"typeName":"App.A2","file":"/src/A.swift","conformances":["AppIntents.AppIntent"]}
      ]
      """, binDirectory: root, module: "App", file: "Intents")

    let files = AppIntentsMetadata.constValueFiles(binDirectory: root, module: "App")
    #expect(
      AppIntentsMetadata.sourceFiles(constValueFiles: files) == ["/src/A.swift", "/src/B.swift"])
  }

  @Test("fails loudly when intents are declared but no toolchain is available")
  func failsWithoutToolchain() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeConstValues(
      #"[{"typeName":"App.PingIntent","file":"/src/P.swift","conformances":["AppIntents.AppIntent"]}]"#,
      binDirectory: root, module: "App", file: "PingIntent")

    #expect(throws: AppIntentsMetadata.MetadataError.self) {
      _ = try AppIntentsMetadata.generate(
        binDirectory: root, modules: ["App"], bundleDirectory: root, toolchain: nil)
    }
  }

  @Test("fails loudly when more than one module declares intents")
  func failsWithMultipleIntentModules() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let contents =
      #"[{"typeName":"App.PingIntent","file":"/src/P.swift","conformances":["AppIntents.AppIntent"]}]"#
    try writeConstValues(contents, binDirectory: root, module: "App", file: "PingIntent")
    try writeConstValues(contents, binDirectory: root, module: "AppCore", file: "PingIntent")

    #expect(throws: AppIntentsMetadata.MetadataError.self) {
      _ = try AppIntentsMetadata.generate(
        binDirectory: root, modules: ["App", "AppCore"], bundleDirectory: root, toolchain: nil)
    }
  }

  @Test("writes the const-gather protocol list")
  func writesProtocolsFile() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("protocols.json")
    try AppIntentsMetadata.writeConstGatherProtocolsFile(to: url)

    let data = try Data(contentsOf: url)
    let protocols = try JSONSerialization.jsonObject(with: data) as? [String]
    #expect(protocols?.contains("AppIntent") == true)
    #expect(protocols?.contains("AppShortcutsProvider") == true)
  }
}
