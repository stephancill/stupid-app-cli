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

        var resources: [BuildPlan.Resource] = []
        let packages = root.productsByName()
        // Walk target dependencies within the root package. Version 1 expects a single
        // self-contained package; dependency packages are resolved by SwiftPM at build
        // time and their resource bundles still appear under the root-target output.
        try collectResources(
            from: library.targets,
            in: root,
            packages: packages,
            into: &resources
        )
        if let configured = config.resources {
            resources += configured.map(BuildPlan.Resource.root)
        }
        resources = Array(Set(resources))

        let deploymentTarget = root.iosDeploymentTarget ?? config.deploymentTarget
        let infoPlist = try synthesizeInfoPlist(
            product: library.name,
            bundleID: config.bundleID,
            deploymentTarget: deploymentTarget,
            platform: platform,
            isExtension: false,
            infoPath: config.infoPath
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
                try collectResources(
                    from: product.targets,
                    in: root,
                    packages: packages,
                    into: &extensionResources
                )
                if let configured = extensionConfig.resources {
                    extensionResources += configured.map(BuildPlan.Resource.root)
                }
                extensionResources = Array(Set(extensionResources))
                let extensionDeploymentTarget =
                    extensionConfig.deploymentTarget ?? root.iosDeploymentTarget ?? config.deploymentTarget
                // Nested bundles root their Info.plist so relative source `Resources`
                // that were copied against the app root are located from the project root.
                let extensionInfo = try synthesizeInfoPlist(
                    product: product.name,
                    bundleID: extensionConfig.bundleID,
                    deploymentTarget: extensionDeploymentTarget,
                    platform: platform,
                    isExtension: true,
                    infoPath: extensionConfig.infoPath
                )
                extensionPlans.append(
                    ExtensionPlan(
                        product: product.name,
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
            deploymentTarget: deploymentTarget,
            bundleID: config.bundleID,
            packageLayoutHash: root.packageLayoutHash,
            infoPlist: infoPlist,
            resources: resources,
            iconPath: config.iconPath,
            entitlementsPath: config.entitlementsPath,
            platform: platform,
            extensions: extensionPlans
        )
    }

    // MARK: - Package description

    private func describePackage(at url: URL) throws -> PackageDump {
        let result = try ProcessRunner.run(
            executable: HostInfo.resolveExecutable(swiftPath),
            arguments: ["package", "--package-path", url.path, "describe", "--type", "json"]
        )
        guard result.succeeded else {
            throw BuildError.processingFailed("swift package describe", result.stderr)
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

    private func collectResources(
        from initialTargets: [String],
        in package: PackageDump,
        packages: [String: PackageDump.Product],
        into resources: inout [BuildPlan.Resource]
    ) throws {
        var seenTargets = Set<String>()
        var pending = initialTargets
        while let targetName = pending.popLast() {
            guard !seenTargets.contains(targetName) else { continue }
            seenTargets.insert(targetName)
            guard let target = package.targets?.first(where: { $0.name == targetName }) else {
                throw BuildError.targetNotFound(targetName, package.name)
            }
            if target.moduleType == "BinaryTarget" {
                throw BuildError.unsupportedModule("binaryTarget '\(targetName)'")
            }
            if let declaredResources = target.resources, !declaredResources.isEmpty {
                resources.append(.bundle(target: targetName))
            }
            for dependency in target.targetDependencies ?? [] {
                pending.append(dependency)
            }
            for productDependency in target.productDependencies ?? [] {
                // A product dependency must resolve within the root package in v1.
                guard let product = packages[productDependency] else {
                    throw BuildError.unsupportedModule("product dependency '\(productDependency)'")
                }
                if product.isDynamicLibrary {
                    resources.append(.library(name: productDependency))
                }
                pending.append(contentsOf: product.targets)
            }
        }
    }

    private func synthesizeInfoPlist(
        product: String, bundleID: String, deploymentTarget: String, platform: TargetPlatform,
        isExtension: Bool, infoPath: String
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
        ]
        if !isExtension {
            info["LSRequiresIPhoneOS"] = true
            info["UIDeviceFamily"] = [1, 2]
            info["UISupportedInterfaceOrientations"] = ["UIInterfaceOrientationPortrait"]
            info["UISupportedInterfaceOrientations~ipad"] = [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight",
            ]
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
        case bundle(target: String)
        case library(name: String)
        case root(source: String)
    }
}

/// A planned nested app extension, assembled into `PlugIns/<product>.appex`.
public struct ExtensionPlan: Sendable {
    public var product: String
    public var bundleID: String
    public var deploymentTarget: String
    public var infoPlist: [String: Sendable]
    public var resources: [BuildPlan.Resource]
    public var entitlementsPath: String?
    public var appIntentsMetadata: String?

    public init(
        product: String,
        bundleID: String,
        deploymentTarget: String,
        infoPlist: [String: Sendable],
        resources: [BuildPlan.Resource],
        entitlementsPath: String? = nil,
        appIntentsMetadata: String? = nil
    ) {
        self.product = product
        self.bundleID = bundleID
        self.deploymentTarget = deploymentTarget
        self.infoPlist = infoPlist
        self.resources = resources
        self.entitlementsPath = entitlementsPath
        self.appIntentsMetadata = appIntentsMetadata
    }
}

private extension PackageDump {
    func productsByName() -> [String: PackageDump.Product] {
        Dictionary(uniqueKeysWithValues: (products ?? []).map { ($0.name, $0) })
    }

    var iosDeploymentTarget: String? {
        platforms?.first { $0.name == "ios" }?.version
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

    let name: String
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
    case infoPlistMissing(String)
    case infoPlistInvalid(String)
    case unsupportedResource(String)
    case missingSimulatorSDK(String)
    case simulatorRequiresXcode

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
            return "Unsupported build input '\(name)'. Version 1 supports pure Swift/PMM resources only; binary targets, plugins, and extensions fail loudly."
        case let .infoPlistMissing(path):
            return "Configured Info.plist '\(path)' does not exist at the project root."
        case let .infoPlistInvalid(path):
            return "Configured Info.plist '\(path)' could not be parsed as a dictionary."
        case let .unsupportedResource(path):
            return "Unsupported resource '\(path)'. Only PNG icons and Planner-recognized SwiftPM resources are supported in version 1."
        case let .missingSimulatorSDK(app):
            return "Xcode at \(app) has no iPhoneSimulator SDK, but a simulator build requires one. Install a simulator runtime or add the iPhoneSimulator platform."
        case .simulatorRequiresXcode:
            return "Simulator builds require an Xcode-present host because simulators cannot exist without Xcode. Build for a physical device or install Xcode."
        }
    }
}
