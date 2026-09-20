import Foundation

/// Generates the `Metadata.appintents` directory a bundle needs for the system to
/// discover App Intents and App Shortcuts. SwiftPM does not run Apple's App Intents
/// metadata step, so the packer emits Swift compiler const-values (`-emit-const-values`)
/// and runs the Xcode toolchain's `appintentsmetadataprocessor` against them.
///
/// Generation is automatic and scoped per bundle: it runs only when a bundle's module
/// actually declares an App Intent or App Shortcuts provider, and it fails loudly when
/// such a module cannot be processed (for example on a host without an Xcode toolchain).
enum AppIntentsMetadata {
  /// The Xcode-toolchain inputs the processor requires. A `nil` toolchain represents a
  /// host that cannot generate metadata (imported-SDK builds without Xcode tools).
  struct Toolchain: Sendable, Equatable {
    var processorURL: URL
    var toolchainDirectory: URL
    var sdkRoot: URL
    var xcodeVersion: String
    var platformFamily: String
    var deploymentTarget: String
    var targetTriple: String
  }

  enum MetadataError: Error, Equatable, Sendable, CustomStringConvertible {
    case processorUnavailable(module: String)
    case multipleIntentModules([String])
    case processorFailed(module: String, output: String)
    case outputMissing(module: String)

    var description: String {
      switch self {
      case .processorUnavailable(let module):
        return """
          Module '\(module)' declares App Intents but the App Intents metadata processor \
          is unavailable. App Intents metadata requires an Xcode toolchain; install Xcode \
          (Xcode-present builds) or remove the App Intents declarations from this build.
          """
      case .multipleIntentModules(let modules):
        return """
          App Intents are declared in more than one module (\(modules.joined(separator: ", "))). \
          The packer generates metadata for a single intent module per bundle; move the \
          declarations into one module.
          """
      case .processorFailed(let module, let output):
        return "appintentsmetadataprocessor failed for module '\(module)'.\n\(output)"
      case .outputMissing(let module):
        return """
          appintentsmetadataprocessor reported success for module '\(module)' but produced \
          no Metadata.appintents/extract.actionsdata.
          """
      }
    }
  }

  /// The Swift protocols whose conformances the App Intents metadata processor consumes.
  /// Xcode derives this list from the AppIntents module and passes it as
  /// `-const-gather-protocols-file`; SwiftPM does not, so the packer supplies it.
  static let constGatherProtocols: [String] = [
    "AnyResolverProviding",
    "AppEntity",
    "AppEnum",
    "AppExtension",
    "AppIntent",
    "AppIntentsPackage",
    "AppShortcutProviding",
    "AppShortcutsProvider",
    "AppUnionValue",
    "AppUnionValueCasesProviding",
    "DynamicOptionsProvider",
    "EntityQuery",
    "ExtensionPointDefining",
    "IntentValueQuery",
    "Resolver",
    "TransientEntity",
    "_AssistantIntentsProvider",
    "_GenerativeFunctionExtractable",
    "_IntentValueRepresentable",
  ]

  /// Writes the protocol list the compiler reads via `-const-gather-protocols-file`.
  static func writeConstGatherProtocolsFile(to url: URL) throws {
    let data = try JSONSerialization.data(
      withJSONObject: constGatherProtocols, options: [.sortedKeys])
    try data.write(to: url, options: .atomic)
  }

  /// Every `.swiftconstvalues` file the compiler emitted for `module` in the SwiftPM
  /// scratch output. An empty result means the module was not compiled in this build.
  static func constValueFiles(binDirectory: URL, module: String) -> [URL] {
    let moduleBuildDirectory = binDirectory.appendingPathComponent(
      "\(module).build", isDirectory: true)
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: moduleBuildDirectory, includingPropertiesForKeys: nil)
    else { return [] }
    return
      entries
      .filter { $0.pathExtension == "swiftconstvalues" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// Whether any const-values file declares an App Intent or App Shortcuts provider.
  static func declaresAppIntents(constValueFiles: [URL]) -> Bool {
    constValueFiles.contains { url in
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
      return text.contains("AppIntents.AppIntent")
        || text.contains("AppIntents.AppShortcutsProvider")
    }
  }

  /// The source paths named by the const-values, used for the processor's source list.
  static func sourceFiles(constValueFiles: [URL]) -> [String] {
    var paths = Set<String>()
    for url in constValueFiles {
      guard let data = try? Data(contentsOf: url),
        let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
      else { continue }
      for entry in entries {
        if let file = entry["file"] as? String { paths.insert(file) }
      }
    }
    return paths.sorted()
  }

  /// Generates `Metadata.appintents` into `bundleDirectory` when one of `modules` declares
  /// App Intents. Returns `false` without side effects when none do.
  @discardableResult
  static func generate(
    binDirectory: URL,
    modules: [String],
    bundleDirectory: URL,
    toolchain: Toolchain?
  ) throws -> Bool {
    let declaring = modules.filter {
      declaresAppIntents(
        constValueFiles: constValueFiles(binDirectory: binDirectory, module: $0))
    }
    guard !declaring.isEmpty else { return false }
    guard declaring.count == 1, let module = declaring.first else {
      throw MetadataError.multipleIntentModules(declaring)
    }
    guard let toolchain,
      FileManager.default.isExecutableFile(atPath: toolchain.processorURL.path)
    else {
      throw MetadataError.processorUnavailable(module: module)
    }

    let files = constValueFiles(binDirectory: binDirectory, module: module)
    let sources = sourceFiles(constValueFiles: files)

    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stupid-app-appintents-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let sourcesList = scratch.appendingPathComponent("sources.txt")
    let constValuesList = scratch.appendingPathComponent("constvalues.txt")
    try sources.joined(separator: "\n").write(
      to: sourcesList, atomically: true, encoding: .utf8)
    try files.map(\.path).joined(separator: "\n").write(
      to: constValuesList, atomically: true, encoding: .utf8)

    let result = try ProcessRunner.run(
      executable: toolchain.processorURL.path,
      arguments: [
        "--output", bundleDirectory.path,
        "--toolchain-dir", toolchain.toolchainDirectory.path,
        "--module-name", module,
        "--sdk-root", toolchain.sdkRoot.path,
        "--xcode-version", toolchain.xcodeVersion,
        "--platform-family", toolchain.platformFamily,
        "--deployment-target", toolchain.deploymentTarget,
        "--target-triple", toolchain.targetTriple,
        "--source-file-list", sourcesList.path,
        "--swift-const-vals-list", constValuesList.path,
      ]
    )
    guard result.succeeded else {
      throw MetadataError.processorFailed(
        module: module, output: result.stderr.isEmpty ? result.stdout : result.stderr)
    }
    let output = bundleDirectory.appendingPathComponent(
      "Metadata.appintents/extract.actionsdata")
    guard FileManager.default.fileExists(atPath: output.path) else {
      throw MetadataError.outputMissing(module: module)
    }
    return true
  }
}
