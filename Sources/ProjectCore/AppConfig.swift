import Foundation
import Yams

/// The typed `stupid-app.yml` project configuration.
public struct AppConfig: Codable, Equatable, Sendable {
    /// Schema version. Version 1 is the only accepted value.
    public var version: Int
    /// The SwiftPM library product name that represents the application.
    public var product: String
    /// The exact bundle identifier, preserved verbatim.
    public var bundleID: String
    /// Minimum iOS deployment target, e.g. "17.0".
    public var deploymentTarget: String
    /// Source Info.plist path relative to the project root.
    public var infoPath: String
    /// Source entitlements plist path relative to the project root.
    public var entitlementsPath: String?
    /// Optional square PNG source icon, relative to the project root.
    public var iconPath: String?
    /// Optional explicit raw resources, relative to the project root.
    public var resources: [String]?

    public init(
        version: Int,
        product: String,
        bundleID: String,
        deploymentTarget: String,
        infoPath: String,
        entitlementsPath: String? = nil,
        iconPath: String? = nil,
        resources: [String]? = nil
    ) {
        self.version = version
        self.product = product
        self.bundleID = bundleID
        self.deploymentTarget = deploymentTarget
        self.infoPath = infoPath
        self.entitlementsPath = entitlementsPath
        self.iconPath = iconPath
        self.resources = resources
    }

    /// Decodes and fully validates a `stupid-app.yml` from data.
    public static func decode(_ data: Data) throws -> AppConfig {
        let config: AppConfig
        do {
            config = try ConfigYAMLDecoder.decode(AppConfig.self, from: data)
        } catch {
            throw ProjectError.malformedConfig(String(describing: error))
        }
        try config.validate()
        return config
    }

    /// Validates schema version, required fields, and path safety. All checks are
    /// performed without touching the filesystem so planning can reject bad input early.
    public func validate(projectRoot: String = ".") throws {
        guard version == 1 else {
            throw ProjectError.unsupportedVersion(version)
        }
        guard !product.isEmpty else {
            throw ProjectError.missingField("product")
        }
        guard Self.isValidProductName(product) else {
            throw ProjectError.invalidProductName(product)
        }
        guard !bundleID.isEmpty else {
            throw ProjectError.missingField("bundleID")
        }
        guard Self.isValidBundleID(bundleID) else {
            throw ProjectError.invalidBundleID(bundleID)
        }
        guard Self.isValidVersion(deploymentTarget) else {
            throw ProjectError.invalidDeploymentTarget(deploymentTarget)
        }
        try Self.validateRelativePath(infoPath, field: "infoPath", projectRoot: projectRoot)
        if let entitlementsPath {
            try Self.validateRelativePath(entitlementsPath, field: "entitlementsPath", projectRoot: projectRoot)
        }
        if let iconPath {
            try Self.validateRelativePath(iconPath, field: "iconPath", projectRoot: projectRoot)
            guard URL(fileURLWithPath: iconPath).pathExtension.lowercased() == "png" else {
                throw ProjectError.iconNotPng(iconPath)
            }
        }
        if let resources {
            for (index, resource) in resources.enumerated() {
                try Self.validateRelativePath(resource, field: "resources[\(index)]", projectRoot: projectRoot)
            }
        }
    }

    /// A product name must be a valid SwiftPM target/module identifier.
    public static func isValidProductName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        var allowedFirst: CharacterSet = ["_"]
        allowedFirst.insert(charactersIn: "a"..."z")
        allowedFirst.insert(charactersIn: "A"..."Z")
        var allowedRest = allowedFirst
        allowedRest.insert(charactersIn: "0"..."9")
        allowedRest.insert("-")
        guard allowedFirst.contains(first) else { return false }
        return name.unicodeScalars.dropFirst().allSatisfy { allowedRest.contains($0) }
    }

    /// A bundle ID must look like reverse-DNS (dot-separated alphanumeric identifiers)
    /// and must not carry a `XTL-` rewrite prefix (project invariant).
    public static func isValidBundleID(_ bundleID: String) -> Bool {
        guard !bundleID.hasPrefix("XTL-") else { return false }
        let components = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count >= 2, !components.contains(where: { $0.isEmpty }) else {
            return false
        }
        for component in components {
            let scalars = component.unicodeScalars
            guard let first = scalars.first else { return false }
            let allowed: CharacterSet = alphanumeric
            guard allowed.contains(first) else { return false }
            guard scalars.allSatisfy({ allowed.contains($0) || $0.value == 0x2D || $0.value == 0x5F }) else {
                return false
            }
        }
        return true
    }

    /// A deployment target must be a non-empty numeric version such as "17.0".
    public static func isValidVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 3, !components.contains(where: { $0.isEmpty }) else {
            return false
        }
        for component in components {
            guard component.unicodeScalars.allSatisfy({ Self.decimal.contains($0) }) else {
                return false
            }
        }
        return true
    }

    /// Rejects absolute paths and path segments that escape the project root.
    public static func validateRelativePath(_ path: String, field: String, projectRoot: String) throws {
        guard !path.hasPrefix("/") else {
            throw ProjectError.absolutePath(field, path)
        }
        // Inspect raw separators; URL(fileURLWithPath:) would silently resolve '..'.
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.contains("..") {
            throw ProjectError.pathEscape(field, path)
        }
    }

    private static let alphanumeric: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "a"..."z")
        set.insert(charactersIn: "A"..."Z")
        set.insert(charactersIn: "0"..."9")
        return set
    }()

    private static let decimal: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "0"..."9")
        return set
    }()
}

enum ConfigYAMLDecoder {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let string = String(decoding: data, as: UTF8.self)
        return try Yams.YAMLDecoder().decode(type, from: string)
    }
}

public enum ProjectError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreadableConfig(String)
    case malformedConfig(String)
    case unsupportedVersion(Int)
    case missingField(String)
    case invalidProductName(String)
    case invalidBundleID(String)
    case invalidDeploymentTarget(String)
    case invalidPaths([String])
    case absolutePath(String, String)
    case pathEscape(String, String)
    case iconNotPng(String)
    case fileExists(String)

    public var description: String {
        switch self {
        case let .unreadableConfig(path):
            return "Could not read stupid-app.yml at '\(path)'."
        case let .malformedConfig(detail):
            return "stupid-app.yml could not be parsed: \(detail)"
        case let .unsupportedVersion(version):
            return "Unsupported stupid-app.yml schema version \(version)."
        case let .missingField(field):
            return "stupid-app.yml is missing required field '\(field)'."
        case let .invalidProductName(name):
            return "Invalid product name '\(name)'. Use a valid Swift identifier."
        case let .invalidBundleID(id):
            return "Invalid bundle identifier '\(id)'. Use reverse-DNS form with no 'XTL-' prefix."
        case let .invalidDeploymentTarget(target):
            return "Invalid deployment target '\(target)'. Use a numeric version such as '17.0'."
        case let .invalidPaths(errors):
            return "Invalid paths in stupid-app.yml:\n  " + errors.joined(separator: "\n  ")
        case let .absolutePath(field, path):
            return "Field '\(field)' must be a relative path; got absolute path '\(path)'."
        case let .pathEscape(field, path):
            return "Field '\(field)' path '\(path)' escapes the project root ('..' segments are not allowed)."
        case let .iconNotPng(path):
            return "iconPath '\(path)' must be a PNG file."
        case let .fileExists(path):
            return "Cannot create project at '\(path)': a file or directory already exists there."
        }
    }
}