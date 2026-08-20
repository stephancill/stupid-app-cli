import Foundation
import ProjectCore
import Testing

@testable import BuildCore

struct PackerCacheTests {
  @Test("uses deterministic persistent builder and scratch directories")
  func persistentBuildDirectories() {
    let projectRoot = URL(fileURLWithPath: "/tmp/PersistentBuild")
    let config = AppConfig(
      version: 1,
      product: "CacheApp",
      bundleID: "net.example.cache-app",
      deploymentTarget: "17.0",
      infoPath: "Info.plist"
    )
    let plan = BuildPlan(
      product: "CacheApp",
      deploymentTarget: "17.0",
      bundleID: "net.example.cache-app",
      infoPlist: [:],
      resources: [],
      iconPath: nil,
      entitlementsPath: nil,
      platform: .device,
      extensions: []
    )
    let packer = Packer(
      projectRoot: projectRoot,
      plan: plan,
      config: config,
      sdkVersion: { "26.2" },
      builderCacheRoot: URL(fileURLWithPath: "/tmp/StupidAppBuilders/project-key")
    )

    #expect(
      packer.builderDirectory(for: "CacheApp").path
        == "/tmp/StupidAppBuilders/project-key/arm64-apple-ios/CacheApp-builder")
    #expect(
      packer.buildScratchDirectory(for: "CacheApp").path
        == "/tmp/PersistentBuild/.build/stupid-app/scratch/arm64-apple-ios/CacheApp")
    #expect(!packer.builderDirectory(for: "CacheApp").path.hasPrefix(projectRoot.path + "/"))
    #expect(Packer.packageIdentity(for: projectRoot) == "persistentbuild")
    #expect(
      Packer.packageIdentity(for: URL(fileURLWithPath: "/tmp/Package.git")) == "package")
  }

  @Test("does not rewrite unchanged generated build inputs")
  func unchangedGeneratedInputs() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = root.appendingPathComponent("Package.swift")
    let contents = Data("generated".utf8)
    try Packer.writeGeneratedFile(contents, to: file)
    let preservedDate = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes(
      [.modificationDate: preservedDate], ofItemAtPath: file.path)

    try Packer.writeGeneratedFile(contents, to: file)

    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect(attributes[.modificationDate] as? Date == preservedDate)
  }
}
