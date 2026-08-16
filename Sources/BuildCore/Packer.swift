import Foundation
import ProjectCore
import SDKCore

/// Builds the configured application with the imported Swift SDK and assembles an
/// unsigned `.app` bundle. Adapted from the reference packer design with the known
/// weaknesses corrected:
///
/// - The real SDK version (not the deployment target) is injected as the linker
///   `-platform_version` SDK field.
/// - Tools resolve through injected configuration rather than hard-coded paths.
/// - Unsupported resources are rejected during planning, never silently copied.
/// - Ephemeral build output and persistent bundle output are separate roots.
public struct Packer: Sendable {
    public var projectRoot: URL
    public var plan: BuildPlan
    public var config: AppConfig
    public var swiftPath: String
    public var targetTriple: String
    public var sdkID: String
    public var sdkVersion: @Sendable () throws -> String
    public var buildConfiguration: BuildConfiguration
    public var scratchRoot: URL

    public init(
        projectRoot: URL,
        plan: BuildPlan,
        config: AppConfig,
        swiftPath: String = "swift",
        targetTriple: String = "arm64-apple-ios",
        sdkID: String = "stupid-app-ios",
        sdkVersion: (@Sendable () throws -> String)? = nil,
        buildConfiguration: BuildConfiguration = .debug,
        scratchRoot: URL? = nil
    ) {
        self.projectRoot = projectRoot
        self.plan = plan
        self.config = config
        self.swiftPath = swiftPath
        self.targetTriple = targetTriple
        self.sdkID = sdkID
        if let sdkVersion {
            self.sdkVersion = sdkVersion
        } else {
            let resolvedSDKID = sdkID
            let resolvedTriple = targetTriple
            let resolvedSwift = swiftPath
            self.sdkVersion = { @Sendable in
                try SDKVersion.resolve(sdkID: resolvedSDKID, targetTriple: resolvedTriple, swiftPath: resolvedSwift)
            }
        }
        self.buildConfiguration = buildConfiguration
        self.scratchRoot = scratchRoot ?? FileManager.default.temporaryDirectory
    }

    // MARK: - Orchestration

    /// Builds the synthetic executable package and assembles the unsigned `.app`.
    /// Returns the `.app` bundle URL.
    public func pack() throws -> URL {
        let sdkVersion = try self.sdkVersion()
        let session = scratchRoot.appendingPathComponent("stupid-app-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: session) }

        let buildDir = session.appendingPathComponent(".build", isDirectory: true)
        let productDir = buildDir
            .appendingPathComponent(targetTriple, isDirectory: true)
            .appendingPathComponent(buildConfiguration.rawValue, isDirectory: true)

        try writeSyntheticPackage(into: session, sdkVersion: sdkVersion)
        try build(sessionRoot: session)

        // Assemble the .app into a sibling directory that survives session cleanup?
        // The bundle must persist; assemble under the persistent output then copy.
        let appDir = session.appendingPathComponent("\(plan.product).app", isDirectory: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        try assembleApp(into: appDir, fromBuildBin: productDir)

        // Move the assembled app to a deterministic output location under the build
        // root so calling code owns a stable path without the UUID scratch segment.
        let outputRoot = projectRoot.appendingPathComponent(".build/\(targetTriple)/\(buildConfiguration.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let output = outputRoot.appendingPathComponent("\(plan.product).app", isDirectory: true)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: appDir, to: output)
        return output
    }

    // MARK: - Synthetic package

    private func writeSyntheticPackage(into session: URL, sdkVersion: String) throws {
        let packageDir = session.appendingPathComponent("builder-package", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)

        let targetName = "\(plan.product)-App"
        let sourcesDir = packageDir.appendingPathComponent("Sources/\(targetName)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        // An empty C source ensures SwiftPM emits the wrapper executable target.
        try Data().write(to: sourcesDir.appendingPathComponent("stub.c"))

        let linkerFlags = Self.linkerSettings(
            deploymentTarget: plan.deploymentTarget,
            sdkVersion: sdkVersion,
            platformName: "ios"
        )
        let package = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "\(plan.product)-Builder",
            platforms: [
                .iOS("\(plan.deploymentTarget)")
            ],
            dependencies: [
                .package(name: "RootPackage", path: "\(projectRoot.path)")
            ],
            targets: [
                .executableTarget(
                    name: "\(targetName)",
                    dependencies: [
                        .product(name: "\(plan.product)", package: "RootPackage"),
                    ],
                    linkerSettings: \(linkerFlags)
                )
            ]
        )
        """
        try Data(package.utf8).write(to: packageDir.appendingPathComponent("Package.swift"))

        // The builder package's scratch must live in the session .build so output is
        // isolated and removed on cleanup.
        let resolved = packageDir.path
        _ = resolved
    }

    /// Build configuration inline; SwiftPM location is per-package, so the builder dir
    /// is passed on the command line.
    private func build(sessionRoot: URL) throws {
        let builderDir = sessionRoot.appendingPathComponent("builder-package", isDirectory: true)
        let scratch = sessionRoot.appendingPathComponent(".build", isDirectory: true)

        let swift = HostInfo.resolveExecutable(swiftPath)
        var environment = ProcessInfo.processInfo.environment
        environment["SDKROOT"] = nil

        let result = try ProcessRunner.run(
            executable: swift,
            arguments: [
                "build",
                "--package-path", builderDir.path,
                "--scratch-path", scratch.path,
                "--configuration", buildConfiguration.rawValue,
                "--swift-sdk", sdkID,
                "--disable-automatic-resolution",
            ],
            environment: environment
        )
        guard result.succeeded else {
            throw BuildError.processingFailed("swift build", result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    // MARK: - Assembly

    private func assembleApp(into appDir: URL, fromBuildBin binDir: URL) throws {
        // Executable: <product>-App target in the bin dir becomes <product> in the app.
        let executable = binDir.appendingPathComponent("\(plan.product)-App")
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw BuildError.processingFailed("app assembly", "Expected executable at \(binDir.path) but it is missing.")
        }
        try FileManager.default.copyItem(at: executable, to: appDir.appendingPathComponent(plan.product))

        // Resource bundles from SwiftPM build output.
        for resource in plan.resources {
            switch resource {
            case let .bundle(target):
                let bundle = binDir.appendingPathComponent("\(target).bundle")
                if FileManager.default.fileExists(atPath: bundle.path) {
                    try? FileManager.default.removeItem(at: appDir.appendingPathComponent("\(target).bundle"))
                    try FileManager.default.copyItem(at: bundle, to: appDir.appendingPathComponent("\(target).bundle"))
                }
            case let .library(name):
                let dylib = binDir.appendingPathComponent("lib\(name).dylib")
                guard FileManager.default.fileExists(atPath: dylib.path) else {
                    throw BuildError.processingFailed("app assembly", "Expected dynamic library lib\(name).dylib but it is missing.")
                }
                let frameworksDir = appDir.appendingPathComponent("Frameworks", isDirectory: true)
                try FileManager.default.createDirectory(at: frameworksDir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: dylib, to: frameworksDir.appendingPathComponent("lib\(name).dylib"))
            case let .root(source):
                let sourceURL = projectRoot.appendingPathComponent(source)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    throw BuildError.unsupportedResource(source)
                }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir)
                if isDir.boolValue {
                    try Self.copyTree(from: sourceURL, to: appDir.appendingPathComponent(sourceURL.lastPathComponent))
                } else {
                    try FileManager.default.copyItem(at: sourceURL, to: appDir.appendingPathComponent(sourceURL.lastPathComponent))
                }
            }
        }

        // Icon.
        if let iconPath = config.iconPath {
            let iconURL = projectRoot.appendingPathComponent(iconPath)
            guard iconURL.pathExtension.lowercased() == "png", FileManager.default.fileExists(atPath: iconURL.path) else {
                throw BuildError.unsupportedResource(iconPath)
            }
            try FileManager.default.copyItem(at: iconURL, to: appDir.appendingPathComponent(iconURL.lastPathComponent))
        }

        // Merged Info.plist.
        var info = plan.infoPlist
        info["CFBundleIconFile"] = config.iconPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: appDir.appendingPathComponent("Info.plist"))
    }

    private static func copyTree(from source: URL, to destination: URL) throws {
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
                try FileManager.default.copyItem(at: child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        }
    }

    private static func linkerSettings(deploymentTarget: String, sdkVersion: String, platformName: String) -> String {
        """
        [
            .unsafeFlags([
                "-Xlinker", "-platform_version", "-Xlinker", "\(platformName)",
                "-Xlinker", "\(deploymentTarget)", "-Xlinker", "\(sdkVersion)",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
            ])
        ]
        """
    }
}

public enum BuildConfiguration: String, CaseIterable, Sendable {
    case debug
    case release
}