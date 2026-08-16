import Foundation

/// Immutable, public-safe release manifest. Records artifact identity and App Store
/// Connect resource IDs after a release upload. Must never contain credentials,
/// private keys, profile content, or personal data.
public struct ReleaseManifest: Codable, Equatable, Sendable {
    public var appBundleId: String
    public var marketingVersion: String
    public var buildNumber: String
    /// IPA path relative to the project root when known, else absolute.
    public var ipaPath: String
    public var ipaSha256: String
    public var buildUploadId: String
    public var buildId: String?
    public var uploadState: String?
    public var processingState: String?
    public var internalBetaState: String?
    public var externalBetaState: String?
    public var toolVersion: String?
    public var signerVersion: String?
    public var sdkVersion: String?
    public var compilerVersion: String?

    public init(
        appBundleId: String,
        marketingVersion: String,
        buildNumber: String,
        ipaPath: String,
        ipaSha256: String,
        buildUploadId: String,
        buildId: String? = nil,
        uploadState: String? = nil,
        processingState: String? = nil,
        internalBetaState: String? = nil,
        externalBetaState: String? = nil,
        toolVersion: String? = nil,
        signerVersion: String? = nil,
        sdkVersion: String? = nil,
        compilerVersion: String? = nil
    ) {
        self.appBundleId = appBundleId
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
        self.ipaPath = ipaPath
        self.ipaSha256 = ipaSha256
        self.buildUploadId = buildUploadId
        self.buildId = buildId
        self.uploadState = uploadState
        self.processingState = processingState
        self.internalBetaState = internalBetaState
        self.externalBetaState = externalBetaState
        self.toolVersion = toolVersion
        self.signerVersion = signerVersion
        self.sdkVersion = sdkVersion
        self.compilerVersion = compilerVersion
    }

    /// Encodes and atomically writes the manifest.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try Self.atomicWrite(data, to: url)
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
    }
}
