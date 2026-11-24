import Foundation
import ProjectCore
import SDKCore

/// Produces a build plan for the configured application without invoking Xcode.
/// Version 1 plans exactly one SwiftPM library product as an iOS application; any
/// extension or unsupported product input fails loudly during planning.
public struct Planner: Sendable {
    public var projectRoot: URL
    public var config: AppConfig
    public var swiftPath: String
    public var targetTriple: String
    public var platform: TargetPlatform

    public init(
        projectRoot: URL,
        config: AppConfig,
        swiftPath: String = "swift",
        targetTriple: String = "arm64-apple-ios",
        platform: TargetPlatform = .device
    ) {
        self.projectRoot = projectRoot
        self.config = config
        self.swiftPath = swiftPath
        self.targetTriple = targetTriple
        self.platform = platform
    }

    /// Builds the plan: selects the library product, walks its dependency graph for
    /// resources, synthesizes the merged Info.plist, and plans any configured
    /// extensions as nested bundles.
    public func makePlan() throws -> BuildPlan {
        let root = try describePackage(at: projectRoot)
        let library = try selectLibrary(from: root.products ?? [], matching: config.product)
        let graph = try packageGraph(root: root)

        var resources: [BuildPlan.Resource] = []
        try collectResources(from: library.targets, in: graph, into: &resources)
        if let configured = config.resources {
            resources += configured.map(BuildPlan.Resource.root)
        }
        resources = Array(Set(resources))

        let deploymentTarget = root.deploymentTarget(for: platform) ?? config.deploymentTarget
        let infoPlist = try synthesizeInfoPlist(
            product: library.name,
            bundleID: config.bundleID,
            deploymentTarget: deploymentTarget,
            platform: platform,
            isExtension: false,
            infoPath: config.infoPath,
            deviceFamily: config.resolvedDeviceFamily
        )

        var extensionPlans: [ExtensionPlan] = []
        if let extensions = config.extensions {
            for extensionConfig in extensions {
                guard let product = root.products?.first(where: {
                    $0.isLibrary && $0.name == extensionConfig.product
                }) else {
                    throw BuildError.extensionProductMissing(
                        extensionConfig.product, config.product)
                }
                var extensionResources: [BuildPlan.Resource] = []
                try collectResources(from: product.targets, in: graph, into: &extensionResources)
                if let configured = extensionConfig.resources {
                    extensionResources += configured.map(BuildPlan.Resource.root)
                }
                extensionResources = Array(Set(extensionResources))
                let extensionDeploymentTarget =
                    extensionConfig.deploymentTarget ?? root.deploymentTarget(for: platform)
                    ?? config.deploymentTarget
                // Nested bundles root their Info.plist so relative source `Resources`
                // that were copied against the app root are located from the project root.
                let extensionInfo = try synthesizeInfoPlist(
                    product: product.name,
                    bundleID: extensionConfig.bundleID,
                    deploymentTarget: extensionDeploymentTarget,
                    platform: platform,
                    isExtension: true,
                    infoPath: extensionConfig.infoPath,
                    deviceFamily: config.resolvedDeviceFamily
                )
                extensionPlans.append(
                    ExtensionPlan(
                        product: product.name,
                        moduleNames: product.targets,
                        bundleID: extensionConfig.bundleID,
                        deploymentTarget: extensionDeploymentTarget,
                        infoPlist: extensionInfo,
                        resources: extensionResources,
                        entitlementsPath: extensionConfig.entitlementsPath,
                        appIntentsMetadata: extensionConfig.appIntentsMetadata
                    )
                )
            }
        }

        return BuildPlan(
            product: library.name,
            moduleNames: library.targets,
            deploymentTarget: deploymentTarget,
            bundleID: config.bundleID,
            packageLayoutHash: graph.layoutHash(resolvedFile: projectRoot.appendingPathComponent("Package.resolved")),
            infoPlist: infoPlist,
            resources: resources,
            iconPath: config.iconPath,
            entitlementsPath: config.entitlementsPath,
            platform: platform,
            extensions: extensionPlans
        )
    }

    // MARK: - Package description

    /// The root package and, when its manifest declares dependencies, every package it
    /// depends on. `show-dependencies` resolves the graph the way `swift build` would,
    /// honoring and writing the project's `Package.resolved`, and reports each package's
    /// checkout; `describe` then reads each manifest without resolving again.
    private func packageGraph(root: PackageDump) throws -> PackageGraph {
        guard !(root.dependencies ?? []).isEmpty else {
            return PackageGraph(
                rootIdentity: PackageGraph.rootKey,
                packages: [PackageGraph.rootKey: .init(dump: root, url: projectRoot, dependencies: [])])
        }
        let result = try ProcessRunner.run(
            executable: HostInfo.resolveExecutable(swiftPath),
            arguments: ["package", "--package-path", projectRoot.path, "show-dependencies", "--format", "json"]
        )
        guard result.succeeded else {
            throw BuildError.dependencyResolutionFailed(result.failureOutput)
        }
        guard let tree = try? JSONDecoder().decode(
            DependencyNode.self, from: Self.JSONData(from: result.stdout))
        else {
            throw BuildError.malformedPackageDescription
        }

        var packages: [String: PackageGraph.Package] = [
            tree.identity: .init(dump: root, url: projectRoot, dependencies: tree.dependencies.map(\.identity)),
        ]
        var pending = tree.dependencies
        while let node = pending.popLast() {
            guard packages[node.identity] == nil else { continue }
            let url = URL(fileURLWithPath: node.path, isDirectory: true)
            packages[node.identity] = .init(
                dump: try describePackage(at: url), url: url, dependencies: node.dependencies.map(\.identity))
            pending += node.dependencies
        }
        return PackageGraph(rootIdentity: tree.identity, packages: packages)
    }

    private func describePackage(at url: URL) throws -> PackageDump {
        let result = try ProcessRunner.run(
            executable: HostInfo.resolveExecutable(swiftPath),
            arguments: ["package", "--package-path", url.path, "describe", "--type", "json"]
        )
        guard result.succeeded else {
            throw BuildError.processingFailed("swift package describe", result.failureOutput)
        }
        // SwiftPM may print extraneous non-JSON output; locate the opening brace.
        let jsonData = Self.JSONData(from: result.stdout)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let dump = try? decoder.decode(PackageDump.self, from: jsonData) else {
            throw BuildError.malformedPackageDescription
        }
        return dump
    }

    /// Locates the first JSON object in command output (leading noise is tolerated).
    private static func JSONData(from string: String) -> Data {
        guard let brace = string.firstIndex(of: "{") else { return Data(string.utf8) }
        return Data(string[brace...].utf8)
    }

    private func selectLibrary(from products: [PackageDump.Product], matching name: String) throws -> PackageDump.Product {
        let libraries = products.filter { $0.isLibrary }
        switch libraries.count {
        case 0:
            throw BuildError.noLibraryProduct
        case 1:
            let product = libraries[0]
            guard product.name == name else {
                throw BuildError.productMismatch(declared: name, found: product.name)
            }
            return product
        default:
            guard let product = libraries.first(where: { $0.name == name }) else {
                throw BuildError.ambiguousLibrary(libraries.map(\.name))
            }
            return product
        }
    }

    /// Walks the targets a product is made of, across packages, for the resource bundles and
    /// dynamic libraries the bundle must carry. A product dependency resolves among the products
    /// of the packages the depending target's package declares.
    private func collectResources(
        from initialTargets: [String],
        in graph: PackageGraph,
        into resources: inout [BuildPlan.Resource]
    ) throws {
        struct Pending: Hashable {
            let target: String
            let package: String
        }
        var seen = Set<Pending>()
        var pending = initialTargets.map { Pending(target: $0, package: graph.rootIdentity) }
        while let next = pending.popLast() {
            guard seen.insert(next).inserted else { continue }
            let package = try graph.package(next.package)
            guard let target = package.dump.targets?.first(where: { $0.name == next.target }) else {
                throw BuildError.targetNotFound(next.target, package.dump.name)
            }
            if target.moduleType == "BinaryTarget" {
                try validateStaticXCFramework(name: target.name, path: target.path, packageRoot: package.url)
                continue
            }
            if let declaredResources = target.resources, !declaredResources.isEmpty {
                resources.append(.bundle(package: package.dump.name, target: target.name))
            }
            pending += (target.targetDependencies ?? []).map { Pending(target: $0, package: next.package) }
            for productName in target.productDependencies ?? [] {
                let (owner, product) = try graph.product(named: productName, dependencyOf: next.package)
                if product.isDynamicLibrary {
                    resources.append(.library(name: productName))
                }
                pending += product.targets.map { Pending(target: $0, package: owner) }
            }
        }
    }

    /// Binary targets are supported only as local XCFrameworks of static archives. Those link into
    /// the executable, so the bundle embeds and signs nothing extra; dynamic frameworks would need
    /// embedding and nested signing, which version 1 does not do.
    func validateStaticXCFramework(name: String, path: String?, packageRoot: URL? = nil) throws {
        guard let path, path.hasSuffix(".xcframework"), !path.hasPrefix("/") else {
            throw BuildError.unsupportedBinaryTarget(
                name, "it is not a local .xcframework inside the package (remote and artifact-bundle binaries are unsupported)")
        }
        let infoURL = (packageRoot ?? projectRoot).appendingPathComponent(path).appendingPathComponent("Info.plist")
        guard
            let data = try? Data(contentsOf: infoURL),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let libraries = info["AvailableLibraries"] as? [[String: Any]], !libraries.isEmpty
        else {
            throw BuildError.unsupportedBinaryTarget(name, "\(path)/Info.plist lists no AvailableLibraries")
        }
        for library in libraries {
            let libraryPath = library["LibraryPath"] as? String ?? "<missing LibraryPath>"
            guard libraryPath.hasSuffix(".a") else {
                throw BuildError.unsupportedBinaryTarget(
                    name, "'\(libraryPath)' is not a static archive (.a)")
            }
        }
        let variant: String? = platform.isSimulator ? "simulator" : nil
        let hasSlice = libraries.contains { library in
            library["SupportedPlatform"] as? String == platform.tripleOS
                && library["SupportedPlatformVariant"] as? String == variant
                && (library["SupportedArchitectures"] as? [String])?.contains("arm64") == true
        }
        guard hasSlice else {
            throw BuildError.unsupportedBinaryTarget(
                name, "it has no arm64 \(platform.os.displayName)\(variant.map { " \($0)" } ?? "") library")
        }
    }

    func synthesizeInfoPlist(
        product: String, bundleID: String, deploymentTarget: String, platform: TargetPlatform,
        isExtension: Bool, infoPath: String, deviceFamily: DeviceFamily
    ) throws -> [String: Sendable] {
        var info: [String: Sendable] = [
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0.0",
            "MinimumOSVersion": deploymentTarget,
            "CFBundleIdentifier": bundleID,
            "CFBundleName": product,
            "CFBundleExecutable": product,
            "CFBundleDisplayName": product,
            "CFBundlePackageType": isExtension ? "XPC!" : "APPL",
            "CFBundleSupportedPlatforms": [platform.supportedPlatformsKey],
            // Both apps and bundled app extensions carry the arm64 slice requirement;
            // ASC rejects 64-bit extensions that omit it.
            "UIRequiredDeviceCapabilities": ["arm64"],
            // The app and every bundled extension declare the same device families so
            // App Store validation never sees an extension supporting more families than
            // its containing app.
            "UIDeviceFamily": platform.os == .tvos ? [3] : deviceFamily.deviceFamilyIdentifiers,
        ]
        if !isExtension, platform.os == .tvos {
            info["LSRequiresIPhoneOS"] = true
        } else if !isExtension {
            info["LSRequiresIPhoneOS"] = true
            info["UISupportedInterfaceOrientations"] = ["UIInterfaceOrientationPortrait"]
            // iPad support requires all four orientations (App Store validation
            // ITMS-90474); an iPhone-only app must not advertise the iPad key.
            if deviceFamily.includesIPad {
                info["UISupportedInterfaceOrientations~ipad"] = [
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationPortraitUpsideDown",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ]
            }
            info["UILaunchScreen"] = [:] as [String: Sendable]
        }

        let sourceURL = projectRoot.appendingPathComponent(infoPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw BuildError.infoPlistMissing(infoPath)
        }
        if let data = try? Data(contentsOf: sourceURL),
           let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Sendable] {
            info.merge(parsed) { _, overlay in overlay }
        } else {
            throw BuildError.infoPlistInvalid(infoPath)
        }
        return info
    }
}

/// The finalized, independent plan data used by the packer.
public struct BuildPlan: Sendable {
    public var product: String
    /// SwiftPM target (module) names that make up the app product. Used to locate the
    /// module that declares App Intents for metadata generation.
    public var moduleNames: [String]
    public var deploymentTarget: String
    public var bundleID: String
    public var packageLayoutHash: String
    public var infoPlist: [String: Sendable]
    public var resources: [Resource]
    public var iconPath: String?
    public var entitlementsPath: String?
    public var platform: TargetPlatform
    public var extensions: [ExtensionPlan]

    public enum Resource: Sendable, Equatable, Hashable {
        /// SwiftPM's `<package>_<target>.bundle`; `package` is the declaring manifest's name.
        case bundle(package: String, target: String)
        case library(name: String)
        case root(source: String)
    }
}

/// A planned nested app extension, assembled into `PlugIns/<product>.appex`.
public struct ExtensionPlan: Sendable {
    public var product: String
    /// SwiftPM target (module) names that make up the extension product.
    public var moduleNames: [String]
    public var bundleID: String
    public var deploymentTarget: String
    public var infoPlist: [String: Sendable]
    public var resources: [BuildPlan.Resource]
    public var entitlementsPath: String?
    public var appIntentsMetadata: String?

    public init(
        product: String,
        moduleNames: [String] = [],
        bundleID: String,
        deploymentTarget: String,
        infoPlist: [String: Sendable],
        resources: [BuildPlan.Resource],
        entitlementsPath: String? = nil,
        appIntentsMetadata: String? = nil
    ) {
        self.product = product
        self.moduleNames = moduleNames
        self.bundleID = bundleID
        self.deploymentTarget = deploymentTarget
        self.infoPlist = infoPlist
        self.resources = resources
        self.entitlementsPath = entitlementsPath
        self.appIntentsMetadata = appIntentsMetadata
    }
}

private extension PackageDump {
    func deploymentTarget(for platform: TargetPlatform) -> String? {
        platforms?.first { $0.name == platform.tripleOS }?.version
    }

    var packageLayoutHash: String {
        var targetDescriptions: [String] = []
        for target in (targets ?? []).sorted(by: { $0.name < $1.name }) {
            targetDescriptions += [
                "target:\(target.name)",
                "module:\(target.moduleType)",
                "path:\(target.path ?? "")",
            ]
            targetDescriptions += (target.sources ?? []).sorted().map { "source:\($0)" }
            targetDescriptions += (target.resources ?? []).map(\.path).sorted().map {
                "resource:\($0)"
            }
            targetDescriptions += (target.targetDependencies ?? []).sorted().map {
                "target-dependency:\($0)"
            }
            targetDescriptions += (target.productDependencies ?? []).sorted().map {
                "product-dependency:\($0)"
            }
        }
        return SHA256.hex(data: Data(targetDescriptions.joined(separator: "\u{0}").utf8))
    }
}

/// The packages a build reads, keyed by SwiftPM package identity.
private struct PackageGraph {
    /// The root's key when the manifest declares no dependencies and nothing is resolved.
    static let rootKey = ""

    struct Package {
        let dump: PackageDump
        let url: URL
        /// Identities of the packages this package's manifest depends on.
        let dependencies: [String]
    }

    let rootIdentity: String
    let packages: [String: Package]

    func package(_ identity: String) throws -> Package {
        guard let package = packages[identity] else {
            throw BuildError.unsupportedModule("package '\(identity)'")
        }
        return package
    }

    /// The product a target of `dependent` names: exactly one of its dependency packages must
    /// export it.
    func product(named name: String, dependencyOf dependent: String) throws -> (package: String, product: PackageDump.Product) {
        let matches = try package(dependent).dependencies.compactMap { identity -> (String, PackageDump.Product)? in
            guard let product = try package(identity).dump.products?.first(where: { $0.name == name }) else { return nil }
            return (identity, product)
        }
        guard matches.count == 1, let match = matches.first else {
            throw BuildError.unsupportedModule(
                "product dependency '\(name)' (\(matches.isEmpty ? "no" : "more than one") dependency package exports it)")
        }
        return match
    }

    /// Every package's target layout, plus the pinned versions, so a change in either rebuilds
    /// from a clean scratch.
    func layoutHash(resolvedFile: URL) -> String {
        guard packages.count > 1 else { return packages[rootIdentity]?.dump.packageLayoutHash ?? "" }
        var parts = packages.keys.sorted().map { "\($0):\(packages[$0]!.dump.packageLayoutHash)" }
        let resolved = (try? Data(contentsOf: resolvedFile)) ?? Data()
        parts.append("resolved:\(SHA256.hex(data: resolved))")
        return SHA256.hex(data: Data(parts.joined(separator: "\u{0}").utf8))
    }
}

/// `swift package show-dependencies --format json`: the root, then each dependency with its
/// checkout path and its own dependencies.
private struct DependencyNode: Decodable {
    let identity: String
    let path: String
    let dependencies: [DependencyNode]
}

private struct PackageDump: Decodable {
    struct Product: Decodable {
        let name: String
        let targets: [String]
        let type: ProductType

        var isLibrary: Bool {
            switch type {
            case .library:
                return true
            case .executable, .other:
                return false
            }
        }

        var isDynamicLibrary: Bool {
            switch type {
            case .library(let kinds): return kinds.contains("dynamic")
            case .executable, .other: return false
            }
        }
    }

    enum ProductType: Decodable {
        case library([String])
        case executable
        case other

        private enum CodingKeys: String, CodingKey {
            case library
            case executable
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let libraries = try container.decodeIfPresent([String].self, forKey: .library) {
                self = .library(libraries)
            } else if container.contains(.executable) {
                self = .executable
            } else {
                self = .other
            }
        }
    }

    struct Target: Decodable {
        let name: String
        let moduleType: String
        let path: String?
        let sources: [String]?
        let productDependencies: [String]?
        let targetDependencies: [String]?
        let resources: [Resource]?
    }

    struct Resource: Decodable {
        let path: String
    }

    struct Platform: Decodable {
        let name: String
        let version: String
    }

    struct Dependency: Decodable {
        let identity: String
    }

    let name: String
    let dependencies: [Dependency]?
    let products: [Product]?
    let targets: [Target]?
    let platforms: [Platform]?
}

public enum BuildError: Error, Equatable, Sendable, CustomStringConvertible {
    case processingFailed(String, String)
    case malformedPackageDescription
    case noLibraryProduct
    case productMismatch(declared: String, found: String)
    case extensionProductMissing(String, String)
    case ambiguousLibrary([String])
    case targetNotFound(String, String)
    case unsupportedModule(String)
    case unsupportedBinaryTarget(String, String)
    case dependencyResolutionFailed(String)
    case infoPlistMissing(String)
    case infoPlistInvalid(String)
    case unsupportedResource(String)
    case missingSimulatorSDK(String)
    case missingPlatformSDK(app: String, platform: String)
    case platformRequiresXcode(String)
    case simulatorRequiresXcode
    case macroPluginMissing(String)
    case swiftVersionMismatch(sdk: String, sdkSwift: String, host: String)

    public var description: String {
        switch self {
        case let .processingFailed(command, stderr):
            return "\(command) failed.\n\(stderr)"
        case .malformedPackageDescription:
            return "`swift package describe` produced malformed output. Ensure the package resolves at this path."
        case .noLibraryProduct:
            return "The package exposes no library product. A stupid-app project must expose exactly one library product."
        case let .productMismatch(declared, found):
            return "stupid-app.yml declares product '\(declared)' but the package exposes '\(found)'."
        case let .extensionProductMissing(product, root):
            return "The package exposes no library product '\(product)' for the configured extension of app '\(root)'. Ensure the extension target is a library product."
        case let .ambiguousLibrary(names):
            return "The package exposes multiple library products (\(names)). Specify the intended product in stupid-app.yml."
        case let .targetNotFound(name, package):
            return "Could not find target '\(name)' in package '\(package)'."
        case let .unsupportedModule(name):
            return "Unsupported build input '\(name)'. Version 1 supports pure Swift/PMM resources and static-library XCFrameworks only; plugins and other inputs fail loudly."
        case let .unsupportedBinaryTarget(name, reason):
            return "Unsupported binary target '\(name)': \(reason). Version 1 links local XCFrameworks of static libraries (.a) with an arm64 slice for the build's platform; repackage the dependency that way or depend on its sources."
        case let .dependencyResolutionFailed(output):
            return "Resolving the package's dependencies failed (`swift package show-dependencies`). Check network access and access to each dependency's repository, then retry or run `swift package resolve` in the project.\n\(output)"
        case let .infoPlistMissing(path):
            return "Configured Info.plist '\(path)' does not exist at the project root."
        case let .infoPlistInvalid(path):
            return "Configured Info.plist '\(path)' could not be parsed as a dictionary."
        case let .unsupportedResource(path):
            return "Unsupported resource '\(path)'. Only PNG icons and Planner-recognized SwiftPM resources are supported in version 1."
        case let .missingSimulatorSDK(app):
            return "Xcode at \(app) has no iPhoneSimulator SDK, but a simulator build requires one. Install a simulator runtime or add the iPhoneSimulator platform."
        case let .missingPlatformSDK(app, platform):
            return "Xcode at \(app) has no \(platform) SDK, but this build requires one. Install the \(platform) platform in Xcode's Components settings."
        case let .platformRequiresXcode(os):
            return "\(os) builds currently require an Xcode-present macOS host; imported SDK bundles cover iOS only."
        case .simulatorRequiresXcode:
            return "Simulator builds require an Xcode-present host because simulators cannot exist without Xcode. Build for a physical device or install Xcode."
        case let .macroPluginMissing(path):
            return "stupid-app-macros is missing at \(path). Imported-SDK builds need it for the SDK's @State, @Entry, @Model and #Preview macros; install it beside stupid-app (Tools/StupidAppMacros, or the release's Linux package) or set STUPID_APP_MACROS."
        case let .swiftVersionMismatch(sdk, sdkSwift, host):
            return "The build's Swift is \(host), but the '\(sdk)' SDK was exported with Swift \(sdkSwift). Use a matching toolchain (check for a `.swift-version` file pinning another version), or import an SDK exported for this Swift."
        }
    }
}
