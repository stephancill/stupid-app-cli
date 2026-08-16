import Foundation

/// The versioned, checksummed SDK export manifest. Written by the exporter into the
/// artifact bundle and read by the Linux importer before registration.
public struct SDKManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var generator: String
    public var generatorVersion: String
    public var sourceXcode: XcodeSource
    public var iphoneosSDKVersion: String
    public var swiftCompiler: SwiftCompiler
    public var hostTriple: String
    public var targetTriple: String
    public var darwinTools: DarwinToolsSource
    /// Map of relative path (with `/` separators, relative to bundle root) to lowercase
    /// hex SHA-256. Symlinks are not hashed; their targets' contents are recorded under
    /// the resolved canonical path.
    public var files: [String: String]

    public init(
        formatVersion: Int,
        generator: String,
        generatorVersion: String,
        sourceXcode: XcodeSource,
        iphoneosSDKVersion: String,
        swiftCompiler: SwiftCompiler,
        hostTriple: String,
        targetTriple: String,
        darwinTools: DarwinToolsSource,
        files: [String: String]
    ) {
        self.formatVersion = formatVersion
        self.generator = generator
        self.generatorVersion = generatorVersion
        self.sourceXcode = sourceXcode
        self.iphoneosSDKVersion = iphoneosSDKVersion
        self.swiftCompiler = swiftCompiler
        self.hostTriple = hostTriple
        self.targetTriple = targetTriple
        self.darwinTools = darwinTools
        self.files = files
    }

    public struct XcodeSource: Codable, Equatable, Sendable {
        public var version: String
        public var build: String

        public init(version: String, build: String) {
            self.version = version
            self.build = build
        }
    }

    public struct SwiftCompiler: Codable, Equatable, Sendable {
        public var version: String
        public var major: Int
        public var minor: Int

        public init(version: String, major: Int, minor: Int) {
            self.version = version
            self.major = major
            self.minor = minor
        }
    }

    public struct DarwinToolsSource: Codable, Equatable, Sendable {
        public var source: String
        public var version: String
        public var sha256: String

        public init(source: String, version: String, sha256: String) {
            self.source = source
            self.version = version
            self.sha256 = sha256
        }
    }

    public static let currentFormatVersion = 1

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SDKManifest {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(SDKManifest.self, from: data)
        guard manifest.formatVersion == currentFormatVersion else {
            throw ManifestError.unsupportedFormatVersion(manifest.formatVersion)
        }
        return manifest
    }
}

public enum ManifestError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedFormatVersion(Int)
    case missingFile(String)

    public var description: String {
        switch self {
        case let .unsupportedFormatVersion(version):
            return "Unsupported SDK manifest format version \(version)."
        case let .missingFile(path):
            return "SDK manifest declares no checksum for '\(path)'."
        }
    }
}
