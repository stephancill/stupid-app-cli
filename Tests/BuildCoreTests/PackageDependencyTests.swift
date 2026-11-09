import Foundation
import ProjectCore
import SDKCore
import Testing

@testable import BuildCore

/// Apps may depend on other packages by URL. Fixture dependencies are local git repositories
/// (`file://`), so resolution runs offline: `App` → `DepKit` (tagged 1.0.0 and 1.1.0, with a
/// resource) → `Leaf` (with a resource).
struct PackageDependencyTests {
  private let config = AppConfig(
    version: 1, product: "DepApp", bundleID: "net.example.dep-app",
    deploymentTarget: "17.0", infoPath: "Info.plist")

  @Test("builds an app with remote dependencies at its pinned versions, with their resources")
  func buildsPinnedDependencies() throws {
    guard let installation = XcodeLocator.detect() else {
      // Building for iOS needs Xcode's SDK on this path.
      return
    }
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let swift = installation.toolchainSwiftURL.path

    let leaf = try makePackage(
      at: container.appendingPathComponent("Leaf"), name: "LeafPkg", product: "Leaf",
      dependency: nil, source: "public let leaf = 1\n")
    try writeResource("leaf", in: leaf, target: "Leaf")
    try git(["init", "-q"], in: leaf)
    try commit(tag: "1.0.0", in: leaf)

    let depKit = try makePackage(
      at: container.appendingPathComponent("DepKit"), name: "DepKitPkg", product: "DepKit",
      dependency: (url: leaf, product: "Leaf"), source: "import Leaf\npublic let depKit = leaf\n")
    try writeResource("one", in: depKit, target: "DepKit")
    try git(["init", "-q"], in: depKit)
    try commit(tag: "1.0.0", in: depKit)
    try writeResource("two", in: depKit, target: "DepKit")
    try commit(tag: "1.1.0", in: depKit)

    let root = container.appendingPathComponent("DepApp", isDirectory: true)
    let app = root.appendingPathComponent("Sources/DepApp", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "DepApp",
        platforms: [.iOS("17.0")],
        products: [.library(name: "DepApp", targets: ["DepApp"])],
        dependencies: [.package(url: "\(depKit.absoluteString)", from: "1.0.0")],
        targets: [.target(name: "DepApp", dependencies: [.product(name: "DepKit", package: "DepKit")])]
    )
    """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try """
    import DepKit
    import SwiftUI

    @main
    struct DepAppApp: App {
        var body: some Scene {
            WindowGroup { Text("\\(depKit)") }
        }
    }
    """.write(to: app.appendingPathComponent("DepApp.swift"), atomically: true, encoding: .utf8)
    try emptyPlist.write(
      to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    // Pin the older release; the build must not float to 1.1.0.
    try run(swift, ["package", "--package-path", root.path, "resolve"])
    try run(swift, ["package", "--package-path", root.path, "resolve", "DepKit", "--version", "1.0.0"])

    let plan = try Planner(projectRoot: root, config: config, swiftPath: swift).makePlan()
    #expect(
      Set(plan.resources)
        == [
          .bundle(package: "DepKitPkg", target: "DepKit"), .bundle(package: "LeafPkg", target: "Leaf"),
        ])

    let packer = Packer(
      projectRoot: root, plan: plan, config: config, swiftPath: swift, sdkID: "stupid-app-ios",
      sdkInput: .xcodeInPlace(installation), buildConfiguration: .debug)
    defer { try? FileManager.default.removeItem(at: packer.builderCacheRoot) }
    let appURL = try packer.pack()
    #expect(try MachOInspector.inspect(at: appURL.appendingPathComponent("DepApp")).cpuArchitecture == "arm64")
    #expect(try resource(in: appURL, bundle: "DepKitPkg_DepKit") == "one")
    #expect(try resource(in: appURL, bundle: "LeafPkg_Leaf") == "leaf")
  }

  @Test("changing the pinned versions changes the layout hash")
  func pinsInvalidateScratch() throws {
    let swift = XcodeLocator.detect()?.toolchainSwiftURL.path ?? "swift"
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let depKit = try makePackage(
      at: container.appendingPathComponent("DepKit"), name: "DepKitPkg", product: "DepKit",
      dependency: nil, source: "public let depKit = 1\n")
    try git(["init", "-q"], in: depKit)
    try commit(tag: "1.0.0", in: depKit)
    try "public let later = 2\n".write(
      to: depKit.appendingPathComponent("Sources/DepKit/Later.swift"), atomically: true, encoding: .utf8)
    try commit(tag: "1.1.0", in: depKit)

    let root = try makePackage(
      at: container.appendingPathComponent("DepApp"), name: "DepApp", product: "DepApp",
      dependency: (url: depKit, product: "DepKit"), source: "import DepKit\n")
    try emptyPlist.write(
      to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    let planner = Planner(projectRoot: root, config: config, swiftPath: swift)

    try run(swift, ["package", "--package-path", root.path, "resolve"])
    try run(swift, ["package", "--package-path", root.path, "resolve", "DepKit", "--version", "1.0.0"])
    let pinned = try planner.makePlan().packageLayoutHash
    #expect(try planner.makePlan().packageLayoutHash == pinned)
    try run(swift, ["package", "--package-path", root.path, "resolve", "DepKit", "--version", "1.1.0"])
    #expect(try planner.makePlan().packageLayoutHash != pinned)
  }

  @Test("copies the project's pins into the builder, and removes them when the project has none")
  func copiesResolvedFile() throws {
    let project = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let builder = project.appendingPathComponent("builder", isDirectory: true)
    try FileManager.default.createDirectory(at: builder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }

    try Data("pins".utf8).write(to: project.appendingPathComponent("Package.resolved"))
    try Packer.copyResolvedFile(from: project, to: builder)
    #expect(try Data(contentsOf: builder.appendingPathComponent("Package.resolved")) == Data("pins".utf8))

    try FileManager.default.removeItem(at: project.appendingPathComponent("Package.resolved"))
    try Packer.copyResolvedFile(from: project, to: builder)
    #expect(!FileManager.default.fileExists(atPath: builder.appendingPathComponent("Package.resolved").path))
  }

  // MARK: Fixtures

  /// A package with one library product of one target, optionally depending on one product of
  /// a package at a `file://` URL from 1.0.0.
  private func makePackage(
    at root: URL, name: String, product: String, dependency: (url: URL, product: String)?, source: String
  ) throws -> URL {
    let sources = root.appendingPathComponent("Sources/\(product)", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let packageDependency = dependency.map {
      ".package(url: \"\($0.url.absoluteString)\", from: \"1.0.0\")"
    }
    let productDependency = dependency.map {
      ".product(name: \"\($0.product)\", package: \"\($0.url.lastPathComponent)\")"
    }
    try """
    // swift-tools-version: 6.0
    import PackageDescription
    let package = Package(
        name: "\(name)",
        platforms: [.iOS("17.0")],
        products: [.library(name: "\(product)", targets: ["\(product)"])],
        dependencies: [\(packageDependency ?? "")],
        targets: [.target(
            name: "\(product)",
            dependencies: [\(productDependency ?? "")],
            resources: [.process("Resources")]
        )]
    )
    """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try source.write(
      to: sources.appendingPathComponent("\(product).swift"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: sources.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    try "".write(
      to: sources.appendingPathComponent("Resources/.keep"), atomically: true, encoding: .utf8)
    return root
  }

  private func writeResource(_ text: String, in package: URL, target: String) throws {
    try text.write(
      to: package.appendingPathComponent("Sources/\(target)/Resources/value.txt"),
      atomically: true, encoding: .utf8)
  }

  private func resource(in app: URL, bundle: String) throws -> String {
    try String(
      contentsOf: app.appendingPathComponent("\(bundle).bundle/value.txt"), encoding: .utf8)
  }

  private func commit(tag: String, in repository: URL) throws {
    try git(["add", "-A"], in: repository)
    try git(
      ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", tag],
      in: repository)
    try git(["tag", tag], in: repository)
  }

  private func git(_ arguments: [String], in repository: URL) throws {
    try run("/usr/bin/git", ["-C", repository.path] + arguments)
  }

  private func run(_ executable: String, _ arguments: [String]) throws {
    let result = try ProcessRunner.run(executable: executable, arguments: arguments)
    guard result.succeeded else {
      throw BuildError.processingFailed(([executable] + arguments).joined(separator: " "), result.failureOutput)
    }
  }

  private var emptyPlist: String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict/></plist>
    """
  }
}
