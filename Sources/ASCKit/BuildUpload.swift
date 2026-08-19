import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// App Store Connect Build Upload resources (`/v1/buildUploads`,
/// `/v1/buildUploadFiles`, `/v1/builds`, and `/v1/builds/{id}/buildBetaDetail`).
/// These operations replace `altool`/Transporter and are implemented directly from the
/// pinned OpenAPI schemas.

// MARK: - Models

/// A Build Upload resource. `state` is one of `AWAITING_UPLOAD`, `PROCESSING`,
/// `FAILED`, or `COMPLETE`; `stateErrors` carries the public `errors` array from the
/// nested `state` object.
public struct ASCBuildUpload: Sendable, Equatable {
    public var id: String
    public var cfBundleShortVersionString: String?
    public var cfBundleVersion: String?
    public var platform: String?
    public var state: String?
    public var stateErrors: [String]
    public var uploadedDate: String?

    public init(
        id: String,
        cfBundleShortVersionString: String? = nil,
        cfBundleVersion: String? = nil,
        platform: String? = nil,
        state: String? = nil,
        stateErrors: [String] = [],
        uploadedDate: String? = nil
    ) {
        self.id = id
        self.cfBundleShortVersionString = cfBundleShortVersionString
        self.cfBundleVersion = cfBundleVersion
        self.platform = platform
        self.state = state
        self.stateErrors = stateErrors
        self.uploadedDate = uploadedDate
    }
}

/// One presigned delivery operation returned for an upload file. Executed exactly as
/// described: method, URL, required headers, byte offset, and length.
public struct DeliveryFileUploadOperation: Sendable, Equatable {
    public var method: String
    public var url: String
    public var length: Int64
    public var offset: Int64
    public var requestHeaders: [String: String]
    public var expiration: String?
    public var partNumber: Int64?
    public var entityTag: String?

    public init(
        method: String,
        url: String,
        length: Int64,
        offset: Int64,
        requestHeaders: [String: String] = [:],
        expiration: String? = nil,
        partNumber: Int64? = nil,
        entityTag: String? = nil
    ) {
        self.method = method
        self.url = url
        self.length = length
        self.offset = offset
        self.requestHeaders = requestHeaders
        self.expiration = expiration
        self.partNumber = partNumber
        self.entityTag = entityTag
    }
}

/// A single checksum value with its algorithm.
public struct ASCChecksumValue: Sendable, Equatable, Codable {
    public var hash: String
    public var algorithm: String

    public init(hash: String, algorithm: String) {
        self.hash = hash
        self.algorithm = algorithm
    }
}

/// Source-file checksums declared for an upload file. `file` may be MD5 or SHA-256;
/// `composite` is always MD5.
public struct ASCSourceFileChecksums: Sendable, Equatable, Codable {
    public var file: ASCChecksumValue?
    public var composite: ASCChecksumValue?

    public init(file: ASCChecksumValue? = nil, composite: ASCChecksumValue? = nil) {
        self.file = file
        self.composite = composite
    }
}

/// A Build Upload File resource: the reserved asset plus its delivery operations.
public struct ASCBuildUploadFile: Sendable, Equatable {
    public var id: String
    public var fileName: String?
    public var fileSize: Int64?
    public var assetDeliveryState: String?
    public var sourceFileChecksums: ASCSourceFileChecksums?
    public var uploadOperations: [DeliveryFileUploadOperation]

    public init(
        id: String,
        fileName: String? = nil,
        fileSize: Int64? = nil,
        assetDeliveryState: String? = nil,
        sourceFileChecksums: ASCSourceFileChecksums? = nil,
        uploadOperations: [DeliveryFileUploadOperation] = []
    ) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.assetDeliveryState = assetDeliveryState
        self.sourceFileChecksums = sourceFileChecksums
        self.uploadOperations = uploadOperations
    }
}

/// A resolved build resource.
public struct ASCBuild: Sendable, Equatable {
    public var id: String
    public var version: String?
    public var processingState: String?
    public var uploadedDate: String?

    public init(id: String, version: String? = nil, processingState: String? = nil, uploadedDate: String? = nil) {
        self.id = id
        self.version = version
        self.processingState = processingState
        self.uploadedDate = uploadedDate
    }
}

/// TestFlight beta detail for a build.
public struct ASCBuildBetaDetail: Sendable, Equatable {
    public var id: String
    public var internalBuildState: String?
    public var externalBuildState: String?

    public init(id: String, internalBuildState: String? = nil, externalBuildState: String? = nil) {
        self.id = id
        self.internalBuildState = internalBuildState
        self.externalBuildState = externalBuildState
    }
}

// MARK: - Operations

public extension ASCOperations {
    /// Resolves the exact App Store Connect app resource for a bundle ID.
    func findApp(bundleID: String) throws -> String? {
        let response = try client.request(
            method: .get,
            path: "apps",
            query: [URLQueryItem(name: "filter[bundleId]", value: bundleID)]
        )
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable { let bundleId: String }
                let attributes: Attributes
            }
            let data: [Data]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.data) else {
            throw ASCError.malformedPayload("apps lookup")
        }
        return envelope.data.first { $0.attributes.bundleId == bundleID }?.id
    }

    /// Creates a Build Upload for an app, marketing version, and build number.
    func createBuildUpload(appID: String, version: String, buildNumber: String, platform: String = "IOS") throws -> ASCBuildUpload {
        let response = try client.request(method: .post, path: "buildUploads", body: [
            "data": [
                "type": "buildUploads",
                "attributes": [
                    "cfBundleShortVersionString": version,
                    "cfBundleVersion": buildNumber,
                    "platform": platform,
                ],
                "relationships": [
                    "app": ["data": ["type": "apps", "id": appID]],
                ],
            ],
        ])
        return try Self.decodeBuildUpload(response.data)
    }

    /// Creates a Build Upload File reservation for the given upload and local file.
    func createBuildUploadFile(buildUploadID: String, fileName: String, fileSize: Int64) throws -> ASCBuildUploadFile {
        let response = try client.request(method: .post, path: "buildUploadFiles", body: [
            "data": [
                "type": "buildUploadFiles",
                "attributes": [
                    "fileName": fileName,
                    "fileSize": fileSize,
                    "assetType": "ASSET",
                    "uti": "com.apple.ipa",
                ],
                "relationships": [
                    "buildUpload": ["data": ["type": "buildUploads", "id": buildUploadID]],
                ],
            ],
        ])
        return try Self.decodeBuildUploadFile(response.data)
    }

    /// Marks an upload file as uploaded with source checksums.
    func updateBuildUploadFile(id: String, sourceFileChecksums: ASCSourceFileChecksums?, uploaded: Bool) throws {
        var attributes: [String: Any] = ["uploaded": uploaded]
        if let sourceFileChecksums {
            attributes["sourceFileChecksums"] = sourceFileChecksums.encode()
        }
        _ = try client.request(method: .patch, path: "buildUploadFiles/\(id)", body: [
            "data": [
                "type": "buildUploadFiles",
                "id": id,
                "attributes": attributes,
            ],
        ])
    }

    /// Fetches a Build Upload by ID, used to poll its terminal state.
    func getBuildUpload(id: String) throws -> ASCBuildUpload {
        let response = try client.request(method: .get, path: "buildUploads/\(id)")
        return try Self.decodeBuildUpload(response.data)
    }

    /// Resolves the exact build for an app, marketing version, and build number by
    /// matching the preReleaseVersion marketing version. Returns nil until the build
    /// is visible.
    func findBuild(appID: String, version: String, buildNumber: String, platform: String = "IOS") throws -> ASCBuild? {
        let response = try client.request(
            method: .get,
            path: "builds",
            query: [
                URLQueryItem(name: "filter[app]", value: appID),
                URLQueryItem(name: "filter[version]", value: buildNumber),
                URLQueryItem(name: "include", value: "preReleaseVersion"),
                URLQueryItem(name: "limit", value: "200"),
            ]
        )
        guard let envelope = try? JSONDecoder().decode(BuildListEnvelope.self, from: response.data) else {
            throw ASCError.malformedPayload("builds lookup")
        }
        return Self.matchBuild(from: envelope.data, included: envelope.included ?? [], version: version, buildNumber: buildNumber)
    }

    /// Matches the exact build from a decoded `builds` list. The build's
    /// `preReleaseVersion` relationship must resolve to an included
    /// `preReleaseVersions` resource whose marketing version equals `version`.
    internal static func matchBuild(from builds: [BuildListEnvelope.Data], included: [BuildListEnvelope.Included], version: String, buildNumber: String) -> ASCBuild? {
        let marketingVersionIDs = Set(included
            .filter { $0.type == "preReleaseVersions" && $0.attributes.version == version }
            .map(\.id))
        for build in builds where build.attributes.version == buildNumber {
            let preReleaseID = build.relationships?.preReleaseVersion?.data?.id
            if let preReleaseID, marketingVersionIDs.contains(preReleaseID) {
                return ASCBuild(
                    id: build.id,
                    version: build.attributes.version,
                    processingState: build.attributes.processingState,
                    uploadedDate: build.attributes.uploadedDate
                )
            }
        }
        return nil
    }

    /// Returns the build number of the most recently uploaded build for an app, or nil
    /// when the app has no builds. Used by `release new-build` to suggest the next one.
    func latestBuildNumber(appID: String) throws -> String? {
        let response = try client.request(
            method: .get,
            path: "builds",
            query: [
                URLQueryItem(name: "filter[app]", value: appID),
                URLQueryItem(name: "sort", value: "-uploadedDate"),
                URLQueryItem(name: "limit", value: "1"),
            ]
        )
        return try Self.decodeLatestBuildNumber(response.data)
    }

    /// Extracts the newest uploaded build number from a `builds` list response.
    static func decodeLatestBuildNumber(_ data: Data) throws -> String? {
        struct Envelope: Decodable {
            struct Data: Decodable {
                struct Attributes: Decodable { let version: String? }
                let attributes: Attributes
            }
            let data: [Data]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload("latest build lookup")
        }
        return envelope.data.first?.attributes.version
    }

    /// Fetches a single build, used to poll processing state.
    func getBuild(id: String) throws -> ASCBuild {
        let response = try client.request(method: .get, path: "builds/\(id)")
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable {
                    let version: String?
                    let processingState: String?
                    let uploadedDate: String?
                }
                let attributes: Attributes
            }
            let data: Data
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.data) else {
            throw ASCError.malformedPayload("build get")
        }
        return ASCBuild(
            id: envelope.data.id,
            version: envelope.data.attributes.version,
            processingState: envelope.data.attributes.processingState,
            uploadedDate: envelope.data.attributes.uploadedDate
        )
    }

    /// Fetches the internal/external beta state for a build.
    func getBuildBetaDetail(buildID: String) throws -> ASCBuildBetaDetail {
        let response = try client.request(method: .get, path: "builds/\(buildID)/buildBetaDetail")
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable {
                    let internalBuildState: String?
                    let externalBuildState: String?
                }
                let attributes: Attributes
            }
            let data: Data
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.data) else {
            throw ASCError.malformedPayload("buildBetaDetail get")
        }
        return ASCBuildBetaDetail(
            id: envelope.data.id,
            internalBuildState: envelope.data.attributes.internalBuildState,
            externalBuildState: envelope.data.attributes.externalBuildState
        )
    }

    // MARK: - Decoding

    static func decodeBuildUpload(_ data: Data) throws -> ASCBuildUpload {
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable {
                    let cfBundleShortVersionString: String?
                    let cfBundleVersion: String?
                    let platform: String?
                    let uploadedDate: String?
                    struct State: Decodable {
                        let state: String?
                        struct Error: Decodable { let code: String? }
                        let errors: [Error]?
                    }
                    let state: State?
                }
                let attributes: Attributes
            }
            let data: Data
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload("buildUploads decode")
        }
        return ASCBuildUpload(
            id: envelope.data.id,
            cfBundleShortVersionString: envelope.data.attributes.cfBundleShortVersionString,
            cfBundleVersion: envelope.data.attributes.cfBundleVersion,
            platform: envelope.data.attributes.platform,
            state: envelope.data.attributes.state?.state,
            stateErrors: (envelope.data.attributes.state?.errors ?? []).compactMap(\.code),
            uploadedDate: envelope.data.attributes.uploadedDate
        )
    }

    static func decodeBuildUploadFile(_ data: Data) throws -> ASCBuildUploadFile {
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable {
                    let fileName: String?
                    let fileSize: Int64?
                    struct AssetDeliveryState: Decodable { let state: String? }
                    let assetDeliveryState: AssetDeliveryState?
                    let sourceFileChecksums: ASCSourceFileChecksums?
                    let uploadOperations: [DeliveryFileUploadOperation]?
                }
                let attributes: Attributes
            }
            let data: Data
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload("buildUploadFiles decode")
        }
        return ASCBuildUploadFile(
            id: envelope.data.id,
            fileName: envelope.data.attributes.fileName,
            fileSize: envelope.data.attributes.fileSize,
            assetDeliveryState: envelope.data.attributes.assetDeliveryState?.state,
            sourceFileChecksums: envelope.data.attributes.sourceFileChecksums,
            uploadOperations: envelope.data.attributes.uploadOperations ?? []
        )
    }
}

// MARK: - Coding helpers

private extension DeliveryFileUploadOperation {
    enum CodingKeys: String, CodingKey {
        case method
        case url
        case length
        case offset
        case requestHeaders
        case expiration
        case partNumber
        case entityTag
    }
}

extension DeliveryFileUploadOperation: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decode(String.self, forKey: .method)
        url = try container.decode(String.self, forKey: .url)
        length = try container.decode(Int64.self, forKey: .length)
        offset = try container.decode(Int64.self, forKey: .offset)
        expiration = try container.decodeIfPresent(String.self, forKey: .expiration)
        partNumber = try container.decodeIfPresent(Int64.self, forKey: .partNumber)
        entityTag = try container.decodeIfPresent(String.self, forKey: .entityTag)
        if let headers = try container.decodeIfPresent([HTTPHeader].self, forKey: .requestHeaders) {
            var dict: [String: String] = [:]
            for header in headers {
                dict[header.name] = header.value
            }
            requestHeaders = dict
        } else {
            requestHeaders = [:]
        }
    }
}

private struct HTTPHeader: Decodable {
    let name: String
    let value: String
}

extension ASCSourceFileChecksums {
    func encode() -> [String: Any] {
        var result: [String: Any] = [:]
        if let file {
            result["file"] = ["hash": file.hash, "algorithm": file.algorithm]
        }
        if let composite {
            result["composite"] = ["hash": composite.hash, "algorithm": composite.algorithm]
        }
        return result
    }
}

// MARK: - Build list envelope (shared by findBuild and its tests)

/// Decodable shape for a `GET /v1/builds` response with an optional
/// `preReleaseVersion` include.
struct BuildListEnvelope: Decodable {
    struct Data: Decodable {
        let id: String
        struct Attributes: Decodable {
            let version: String?
            let processingState: String?
            let uploadedDate: String?
        }
        struct PreReleaseVersion: Decodable {
            struct RelationshipData: Decodable { let id: String }
            let data: RelationshipData?
        }
        struct Relationships: Decodable { let preReleaseVersion: PreReleaseVersion? }
        let attributes: Attributes
        let relationships: Relationships?
    }
    struct Included: Decodable {
        let type: String?
        let id: String
        struct Attributes: Decodable { let version: String? }
        let attributes: Attributes
    }
    let data: [Data]
    let included: [Included]?
}
