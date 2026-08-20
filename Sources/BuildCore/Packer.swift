import Foundation
import ProjectCore
import SDKCore

/// Builds the configured application and assembles an unsigned `.app` bundle. Adapted
/// from the reference packer design with the known weaknesses corrected:
///
/// - The real SDK version (not the deployment target) is injected as the linker
///   `-platform_version` SDK field.
/// - Tools resolve through injected configuration rather than hard-coded paths.
/// - Unsupported resources are rejected during planning, never silently copied.
/// - Ephemeral build output and persistent bundle output are separate roots.
/// - Synthetic packages and SwiftPM scratch data persist across invocations.
///
/// The SDK input is host-mode-selected: when a usable Xcode with an iPhoneOS SDK is
/// present, build in place through Xcode's `swift`, its iPhoneOS SDK, and its own
/// linker; otherwise build through the imported `stupid-app` artifact bundle.
public enum SDKInput: Sendable, Equatable {
  case importedBundle(sdkID: String)
  case xcodeInPlace(XcodeInstallation)
}

/// Build-system Info.plist provenance keys injected from either the SDK export
/// manifest (imported bundle) or Xcode's own metadata (Xcode in place).
/// `BuildMachineOSBuild` is never emitted.
public struct BuildSystemMetadata: Sendable, Equatable {
  public var iphoneosSDKVersion: String
  public var xcodeVersion: String
  public var xcodeBuild: String

  public init(iphoneosSDKVersion: String, xcodeVersion: String, xcodeBuild: String) {
    self.iphoneosSDKVersion = iphoneosSDKVersion
    self.xcodeVersion = xcodeVersion
    self.xcodeBuild = xcodeBuild
  }
}

public struct Packer: Sendable {
  public var projectRoot: URL
  public var plan: BuildPlan
  public var config: AppConfig
  public var swiftPath: String
  public var targetTriple: String
  public var sdkID: String
  public var sdkInput: SDKInput
  public var sdkVersion: @Sendable () throws -> String
  public var buildConfiguration: BuildConfiguration
  public var buildCacheRoot: URL
  public var builderCacheRoot: URL

  public init(
    projectRoot: URL,
    plan: BuildPlan,
    config: AppConfig,
    swiftPath: String = "swift",
    targetTriple: String = "arm64-apple-ios",
    sdkID: String = "stupid-app-ios",
    sdkInput: SDKInput? = nil,
    sdkVersion: (@Sendable () throws -> String)? = nil,
    buildConfiguration: BuildConfiguration = .debug,
    buildCacheRoot: URL? = nil,
    builderCacheRoot: URL? = nil
  ) {
    self.projectRoot = projectRoot
    self.plan = plan
    self.config = config
    self.swiftPath = swiftPath
    self.targetTriple = targetTriple
    self.sdkID = sdkID
    let input = sdkInput ?? .importedBundle(sdkID: sdkID)
    self.sdkInput = input
    if let sdkVersion {
      self.sdkVersion = sdkVersion
    } else {
      switch input {
      case .xcodeInPlace(let installation):
        switch plan.platform {
        case .device:
          self.sdkVersion = { @Sendable in installation.iphoneosSDKVersion }
        case .simulator:
          let simulatorVersion = installation.iphoneSimulatorSDKVersion
          self.sdkVersion = { @Sendable in
            guard let simulatorVersion else {
              throw BuildError.missingSimulatorSDK(installation.appURL.path)
            }
            return simulatorVersion
          }
        }
      case .importedBundle(let sdkID):
        let resolvedSDKID = sdkID
        let resolvedTriple = targetTriple
        let resolvedSwift = swiftPath
        self.sdkVersion = { @Sendable in
          try SDKVersion.resolve(
            sdkID: resolvedSDKID, targetTriple: resolvedTriple, swiftPath: resolvedSwift)
        }
      }
    }
    self.buildConfiguration = buildConfiguration
    self.buildCacheRoot =
      buildCacheRoot
      ?? projectRoot.appendingPathComponent(
        ".build/stupid-app", isDirectory: true)
    self.builderCacheRoot = builderCacheRoot ?? Self.defaultBuilderCacheRoot(for: projectRoot)
  }

  // MARK: - Orchestration

  /// Builds the configured application and assembles an unsigned `.app` bundle,
  /// including any configured extensions as `PlugIns/<product>.appex` nested bundles.
  /// Returns the `.app` bundle URL.
  public func pack() throws -> URL {
    let sdkVersion = try self.sdkVersion()
    let session = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stupid-app-build-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: session) }

    // Build the app product and assemble the unsigned .app.
    let appBuildDir = try buildProduct(
      plan.product, isExtension: false, sdkVersion: sdkVersion)
    let appDir = session.appendingPathComponent("\(plan.product).app", isDirectory: true)
    try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
    try assembleApp(into: appDir, fromBuildBin: appBuildDir)

    // Build and assemble each configured extension into PlugIns/<product>.appex.
    if !plan.extensions.isEmpty {
      let pluginsDir = appDir.appendingPathComponent("PlugIns", isDirectory: true)
      try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
      for extensionPlan in plan.extensions {
        let extensionBuildDir = try buildProduct(
          extensionPlan.product, isExtension: true, sdkVersion: sdkVersion)
        let appexDir = pluginsDir.appendingPathComponent(
          "\(extensionPlan.product).appex", isDirectory: true)
        try FileManager.default.createDirectory(at: appexDir, withIntermediateDirectories: true)
        try assembleAppex(
          into: appexDir, fromBuildBin: extensionBuildDir, extensionPlan: extensionPlan)
      }
    }

    // Move the assembled app to a deterministic output location under the build
    // root so calling code owns a stable path without the UUID scratch segment.
    let outputRoot = projectRoot.appendingPathComponent(
      ".build/\(targetTriple)/\(buildConfiguration.rawValue)", isDirectory: true)
    try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    let output = outputRoot.appendingPathComponent("\(plan.product).app", isDirectory: true)
    try? FileManager.default.removeItem(at: output)
    try FileManager.default.moveItem(at: appDir, to: output)
    return output
  }

  /// Builds one SwiftPM library product (the app or an extension) through a synthetic
  /// executable package and returns its build output directory. Extension products link
  /// with the `_NSExtensionMain` entry point and `libextension`, as the App Store
  /// requires.
  private func buildProduct(
    _ product: String, isExtension: Bool, sdkVersion: String
  ) throws -> URL {
    let builderDir = builderDirectory(for: product)
    let scratch = buildScratchDirectory(for: product)
    try writeSyntheticPackage(
      into: builderDir, product: product, sdkVersion: sdkVersion, isExtension: isExtension)
    try build(builderDir: builderDir, scratch: scratch)
    return
      scratch
      .appendingPathComponent(targetTriple, isDirectory: true)
      .appendingPathComponent(buildConfiguration.rawValue, isDirectory: true)
  }

  func builderDirectory(for product: String) -> URL {
    builderCacheRoot
      .appendingPathComponent(targetTriple, isDirectory: true)
      .appendingPathComponent("\(product)-builder", isDirectory: true)
  }

  func buildScratchDirectory(for product: String) -> URL {
    buildCacheRoot
      .appendingPathComponent("scratch", isDirectory: true)
      .appendingPathComponent(targetTriple, isDirectory: true)
      .appendingPathComponent(product, isDirectory: true)
  }

  private static func defaultBuilderCacheRoot(for projectRoot: URL) -> URL {
    let userCache =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let canonicalProjectPath = projectRoot.standardizedFileURL.resolvingSymlinksInPath().path
    let projectKey = SHA256.hex(data: Data(canonicalProjectPath.utf8)).prefix(16)
    return
      userCache
      .appendingPathComponent("stupid-app/builders", isDirectory: true)
      .appendingPathComponent(String(projectKey), isDirectory: true)
  }

  // MARK: - Synthetic package

  private func writeSyntheticPackage(
    into packageDir: URL, product: String, sdkVersion: String, isExtension: Bool
  ) throws {
    try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)

    let targetName = "\(product)-App"
    let sourcesDir = packageDir.appendingPathComponent("Sources/\(targetName)", isDirectory: true)
    try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

    // An empty C source ensures SwiftPM emits the wrapper executable target.
    try Self.writeGeneratedFile(Data(), to: sourcesDir.appendingPathComponent("stub.c"))

    let linkerFlags = Self.linkerSettings(
      deploymentTarget: plan.deploymentTarget,
      sdkVersion: sdkVersion,
      platformName: plan.platform.linkerPlatformName,
      isExtension: isExtension
    )
    let rootPackageIdentity = Self.packageIdentity(for: projectRoot)
    let package = """
      // swift-tools-version: 6.0
      import PackageDescription
      let package = Package(
          name: "\(product)-Builder",
          platforms: [
              .iOS("\(plan.deploymentTarget)")
          ],
          dependencies: [
              .package(path: "\(projectRoot.path)")
          ],
          targets: [
              .executableTarget(
                  name: "\(targetName)",
                  dependencies: [
                      .product(name: "\(product)", package: "\(rootPackageIdentity)"),
                  ],
                  linkerSettings: \(linkerFlags)
              )
          ]
      )
      """
    try Self.writeGeneratedFile(
      Data(package.utf8), to: packageDir.appendingPathComponent("Package.swift"))
  }

  static func writeGeneratedFile(_ data: Data, to destination: URL) throws {
    if let existing = try? Data(contentsOf: destination), existing == data {
      return
    }
    try data.write(to: destination)
  }

  static func packageIdentity(for packageRoot: URL) -> String {
    let name = packageRoot.standardizedFileURL.lastPathComponent
    return name.lowercased().hasSuffix(".git")
      ? String(name.dropLast(4)).lowercased()
      : name.lowercased()
  }

  /// Build configuration inline; SwiftPM location is per-package, so the builder dir
  /// and scratch are passed explicitly.
  private func build(builderDir: URL, scratch: URL) throws {
    let swift: String
    var arguments: [String]
    switch sdkInput {
    case .xcodeInPlace(let installation):
      // Xcode in place: build against Xcode's SDK with Xcode's toolchain `swift` and
      // Xcode's own linker. The explicit `--sdk`/`--triple` replace the `--swift-sdk`
      // bundle so no artifact SDK is registered or materialized.
      let sdkURL: URL
      switch plan.platform {
      case .device:
        sdkURL = installation.iphoneOSSDKURL
      case .simulator:
        guard let simulatorSDK = installation.iphoneSimulatorSDKURL else {
          throw BuildError.missingSimulatorSDK(installation.appURL.path)
        }
        sdkURL = simulatorSDK
      }
      swift = installation.toolchainSwiftURL.path
      arguments = [
        "build",
        "--package-path", builderDir.path,
        "--scratch-path", scratch.path,
        "--configuration", buildConfiguration.rawValue,
        "--sdk", sdkURL.path,
        "--triple", targetTriple,
        "--disable-automatic-resolution",
      ]
    case .importedBundle(let sdkID):
      guard plan.platform == .device else {
        throw BuildError.simulatorRequiresXcode
      }
      swift = HostInfo.resolveExecutable(swiftPath)
      arguments = [
        "build",
        "--package-path", builderDir.path,
        "--scratch-path", scratch.path,
        "--configuration", buildConfiguration.rawValue,
        "--swift-sdk", sdkID,
        "--disable-automatic-resolution",
      ]
    }

    var environment = ProcessInfo.processInfo.environment
    environment["SDKROOT"] = nil

    let result = try ProcessRunner.run(
      executable: swift,
      arguments: arguments,
      environment: environment
    )
    guard result.succeeded else {
      throw BuildError.processingFailed(
        "swift build", result.stderr.isEmpty ? result.stdout : result.stderr)
    }
  }

  // MARK: - Assembly

  private func assembleApp(into appDir: URL, fromBuildBin binDir: URL) throws {
    // Executable: <product>-App target in the bin dir becomes <product> in the app.
    let executable = binDir.appendingPathComponent("\(plan.product)-App")
    guard FileManager.default.fileExists(atPath: executable.path) else {
      throw BuildError.processingFailed(
        "app assembly", "Expected executable at \(binDir.path) but it is missing.")
    }
    try FileManager.default.copyItem(
      at: executable, to: appDir.appendingPathComponent(plan.product))

    // Resource bundles from SwiftPM build output.
    for resource in plan.resources {
      switch resource {
      case .bundle(let target):
        let bundle = binDir.appendingPathComponent("\(target).bundle")
        if FileManager.default.fileExists(atPath: bundle.path) {
          try? FileManager.default.removeItem(at: appDir.appendingPathComponent("\(target).bundle"))
          try FileManager.default.copyItem(
            at: bundle, to: appDir.appendingPathComponent("\(target).bundle"))
        }
      case .library(let name):
        let dylib = binDir.appendingPathComponent("lib\(name).dylib")
        guard FileManager.default.fileExists(atPath: dylib.path) else {
          throw BuildError.processingFailed(
            "app assembly", "Expected dynamic library lib\(name).dylib but it is missing.")
        }
        let frameworksDir = appDir.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(
          at: frameworksDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
          at: dylib, to: frameworksDir.appendingPathComponent("lib\(name).dylib"))
      case .root(let source):
        let sourceURL = projectRoot.appendingPathComponent(source)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
          throw BuildError.unsupportedResource(source)
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir)
        if isDir.boolValue {
          try Self.copyTree(
            from: sourceURL, to: appDir.appendingPathComponent(sourceURL.lastPathComponent))
        } else {
          try FileManager.default.copyItem(
            at: sourceURL, to: appDir.appendingPathComponent(sourceURL.lastPathComponent))
        }
      }
    }

    // Icon: generate the full App Store icon set from one square source PNG,
    // plus a compiled `Assets.car` so App Store Connect can resolve
    // `CFBundleIconName` for iOS 11+ SDK builds.
    if let iconPath = config.iconPath {
      let iconURL = projectRoot.appendingPathComponent(iconPath)
      guard iconURL.pathExtension.lowercased() == "png" else {
        throw BuildError.unsupportedResource(iconPath)
      }
      try IconGenerator.generate(sourceURL: iconURL, outputDirectory: appDir)
      try AssetCatalogWriter.generate(sourceURL: iconURL, outputDirectory: appDir)
    }

    // Merged Info.plist.
    var info = plan.infoPlist
    if config.iconPath != nil {
      Self.injectIconKeys(into: &info)
    }
    Self.injectBuildSystemKeys(
      into: &info, metadata: try resolveBuildSystemMetadata(), platform: plan.platform)
    let infoData = try PropertyListSerialization.data(
      fromPropertyList: info, format: .xml, options: 0)
    try infoData.write(to: appDir.appendingPathComponent("Info.plist"))
  }

  private func assembleAppex(
    into appexDir: URL, fromBuildBin binDir: URL, extensionPlan: ExtensionPlan
  ) throws {
    // Executable: <product>-App target in the bin dir becomes <product> in the appex.
    let executable = binDir.appendingPathComponent("\(extensionPlan.product)-App")
    guard FileManager.default.fileExists(atPath: executable.path) else {
      throw BuildError.processingFailed(
        "extension assembly", "Expected executable at \(binDir.path) but it is missing.")
    }
    try FileManager.default.copyItem(
      at: executable, to: appexDir.appendingPathComponent(extensionPlan.product))

    // Resource bundles and raw resources from the extension's SwiftPM output.
    for resource in extensionPlan.resources {
      switch resource {
      case .bundle(let target):
        let bundle = binDir.appendingPathComponent("\(target).bundle")
        if FileManager.default.fileExists(atPath: bundle.path) {
          try? FileManager.default.removeItem(
            at: appexDir.appendingPathComponent("\(target).bundle"))
          try FileManager.default.copyItem(
            at: bundle, to: appexDir.appendingPathComponent("\(target).bundle"))
        }
      case .library(let name):
        let dylib = binDir.appendingPathComponent("lib\(name).dylib")
        guard FileManager.default.fileExists(atPath: dylib.path) else {
          throw BuildError.processingFailed(
            "extension assembly", "Expected dynamic library lib\(name).dylib but it is missing.")
        }
        let frameworksDir = appexDir.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(
          at: frameworksDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
          at: dylib, to: frameworksDir.appendingPathComponent("lib\(name).dylib"))
      case .root(let source):
        let sourceURL = projectRoot.appendingPathComponent(source)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
          throw BuildError.unsupportedResource(source)
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir)
        if isDir.boolValue {
          try Self.copyTree(
            from: sourceURL, to: appexDir.appendingPathComponent(sourceURL.lastPathComponent))
        } else {
          try FileManager.default.copyItem(
            at: sourceURL, to: appexDir.appendingPathComponent(sourceURL.lastPathComponent))
        }
      }
    }

    // Pack a declared App Intents metadata directory at the appex root
    // (e.g. WidgetMetadata/Metadata.appintents), preserving the leaf name.
    if let appIntentsMetadata = extensionPlan.appIntentsMetadata {
      let sourceURL = projectRoot.appendingPathComponent(appIntentsMetadata)
      guard FileManager.default.fileExists(atPath: sourceURL.path) else {
        throw BuildError.unsupportedResource(appIntentsMetadata)
      }
      try Self.copyTree(
        from: sourceURL, to: appexDir.appendingPathComponent(sourceURL.lastPathComponent))
    }

    // Merged Info.plist.
    var info = extensionPlan.infoPlist
    Self.injectBuildSystemKeys(
      into: &info, metadata: try resolveBuildSystemMetadata(), platform: plan.platform)
    let infoData = try PropertyListSerialization.data(
      fromPropertyList: info, format: .xml, options: 0)
    try infoData.write(to: appexDir.appendingPathComponent("Info.plist"))
  }

  static func injectIconKeys(into info: inout [String: Sendable]) {
    info["CFBundleIconName"] = "AppIcon"
    let phonePrimaryIcon: [String: Sendable] = [
      "CFBundleIconFiles": ["Icon-20", "Icon-29", "Icon-40", "Icon-60"],
      "CFBundleIconName": "AppIcon",
    ]
    let padPrimaryIcon: [String: Sendable] = [
      "CFBundleIconFiles": ["Icon-20", "Icon-29", "Icon-40", "Icon-76", "Icon-83.5"],
      "CFBundleIconName": "AppIcon",
    ]
    info["CFBundleIcons"] = ["CFBundlePrimaryIcon": phonePrimaryIcon]
    info["CFBundleIcons~ipad"] = ["CFBundlePrimaryIcon": padPrimaryIcon]
  }

  /// Resolves the build-system provenance used by App Store Connect. The imported
  /// bundle reads the installed SDK bundle's `sdk-manifest.json`; Xcode in place reads
  /// Xcode's metadata directly. A resolution failure is fatal because the resulting
  /// IPA would otherwise be rejected during processing.
  private func resolveBuildSystemMetadata() throws -> BuildSystemMetadata {
    switch sdkInput {
    case .xcodeInPlace(let installation):
      switch plan.platform {
      case .device:
        return BuildSystemMetadata(
          iphoneosSDKVersion: installation.iphoneosSDKVersion,
          xcodeVersion: installation.version,
          xcodeBuild: installation.build
        )
      case .simulator:
        guard let simulatorVersion = installation.iphoneSimulatorSDKVersion else {
          throw BuildError.missingSimulatorSDK(installation.appURL.path)
        }
        return BuildSystemMetadata(
          iphoneosSDKVersion: simulatorVersion,
          xcodeVersion: installation.version,
          xcodeBuild: installation.build
        )
      }
    case .importedBundle(let sdkID):
      guard plan.platform == .device else {
        throw BuildError.simulatorRequiresXcode
      }
      guard
        let bundle = try SDKVersion.installedBundle(
          sdkID: sdkID,
          targetTriple: targetTriple,
          swiftPath: swiftPath
        )
      else {
        throw BuildError.processingFailed(
          "sdk manifest", "The installed Swift SDK bundle could not be located.")
      }
      let manifestURL = bundle.appendingPathComponent("sdk-manifest.json")
      guard let data = try? Data(contentsOf: manifestURL) else {
        throw BuildError.processingFailed(
          "sdk manifest", "The installed SDK bundle has no sdk-manifest.json.")
      }
      let manifest = try SDKManifest.decode(data)
      return BuildSystemMetadata(
        iphoneosSDKVersion: manifest.iphoneosSDKVersion,
        xcodeVersion: manifest.sourceXcode.version,
        xcodeBuild: manifest.sourceXcode.build
      )
    }
  }

  /// Injects the build-system keys App Store Connect requires: `DTPlatformName`,
  /// `DTSDKName`, `DTXcode`, `DTXcodeBuild`, `DTCompiler`, and platform/SDK versions.
  /// Values come from the source toolchain so the IPA records the real build.
  static func injectBuildSystemKeys(
    into info: inout [String: Sendable],
    metadata: BuildSystemMetadata,
    platform: TargetPlatform = .device
  ) {
    info["DTPlatformName"] = platform.sdkPlatformName
    info["DTPlatformVersion"] = metadata.iphoneosSDKVersion
    info["DTSDKName"] = "\(platform.sdkPlatformName)\(metadata.iphoneosSDKVersion)"
    info["DTXcode"] = Self.numericXcodeVersion(metadata.xcodeVersion)
    info["DTXcodeBuild"] = metadata.xcodeBuild
    info["DTCompiler"] = "com.apple.compilers.llvm.clang.1_0"
    info["BuildMachineOSBuild"] = nil
  }

  /// Converts an Xcode version like "26.1.1" to the numeric form App Store Connect
  /// records (e.g. "2611").
  static func numericXcodeVersion(_ version: String) -> String {
    version
      .split(separator: ".")
      .prefix(3)
      .map(String.init)
      .joined()
  }

  private static func copyTree(from source: URL, to destination: URL) throws {
    try FileManager.default.createDirectory(
      at: destination, withIntermediateDirectories: true)
    let contents = try FileManager.default.contentsOfDirectory(
      at: source,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: []
    )
    for child in contents {
      let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
        guard !target.hasPrefix("/") else {
          throw ExportError.unexpectedSymlink(child.path)
        }
        try FileManager.default.createSymbolicLink(
          at: destination.appendingPathComponent(child.lastPathComponent),
          withDestinationURL: destination.appendingPathComponent(target)
        )
      } else if values.isDirectory == true {
        let dest = destination.appendingPathComponent(child.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try copyTree(from: child, to: dest)
      } else {
        try FileManager.default.copyItem(
          at: child, to: destination.appendingPathComponent(child.lastPathComponent))
      }
    }
  }

  private static func linkerSettings(
    deploymentTarget: String, sdkVersion: String, platformName: String, isExtension: Bool
  ) -> String {
    var flags: [String] = [
      "-Xlinker", "-platform_version", "-Xlinker", platformName,
      "-Xlinker", deploymentTarget, "-Xlinker", sdkVersion,
      "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
    ]
    if isExtension {
      // App extensions must use the NSExtensionMain entry point and link the
      // extension runtime (libextension); the App Store rejects the default _main.
      flags += ["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]
    }
    let flagItems = flags.map { "\"\($0)\"" }.joined(separator: ", ")
    let libraryLink = isExtension ? ",\n        .linkedLibrary(\"extension\")" : ""
    return
      """
      [
          .unsafeFlags([
              \(flagItems)
          ])\(libraryLink)
      ]
      """
  }
}

public enum BuildConfiguration: String, CaseIterable, Sendable {
  case debug
  case release
}
