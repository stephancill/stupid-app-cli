import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// App Store Connect operations required by the distribution signing pipeline. Each
/// operation keeps its responses typed and passes raw outcomes through to the caller
/// so upload verification can persist redacted copies without re-hitting the API.
public struct ASCOperations: Sendable {
    public var client: ASCClient

    public init(client: ASCClient) {
        self.client = client
    }

    // MARK: - Bundle IDs

    /// Finds the exact bundle-ID resource. Asc API `filter[identifier]` is substring-ish,
    /// so the result is exact-matched locally.
    public func findBundleID(identifier: String) throws -> String? {
        let response = try client.request(
            method: .get,
            path: "bundleIds",
            query: [URLQueryItem(name: "filter[identifier]", value: identifier)]
        )
        let data = response.data
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable {
                    let identifier: String
                }
                let attributes: Attributes
            }
            let data: [Data]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload("bundleIds lookup")
        }
        return envelope.data.first { $0.attributes.identifier == identifier }?.id
    }

    /// Registers an explicit bundle ID with a derived human-readable display name.
    public func createBundleID(name: String, identifier: String) throws -> String {
        let response = try client.request(method: .post, path: "bundleIds", body: [
            "data": [
                "type": "bundleIds",
                "attributes": [
                    "name": Self.displayName(from: name),
                    "identifier": identifier,
                    "platform": "IOS",
                ],
            ],
        ])
        let data = response.data
        struct Envelope: Decodable {
            struct Data: Decodable { let id: String }
            let data: Data
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload("bundleIds create")
        }
        return envelope.data.id
    }

    public func getOrCreateBundleID(name: String, identifier: String) throws -> String {
        if let existing = try findBundleID(identifier: identifier) {
            return existing
        }
        return try createBundleID(name: name, identifier: identifier)
    }

    // MARK: - Bundle ID capabilities (App Groups)

    /// Enables a capability (e.g. `APP_GROUPS`) on a bundle-ID resource if it is not
    /// already present. The public API can enable the capability but cannot create or
    /// associate the concrete resource (e.g. an App Group identifier); that is a manual
    /// Developer Portal step that the profile-authorization gate enforces.
    public func enableBundleIDCapability(bundleIDResourceID: String, capabilityType: String) throws {
        let existing = try listBundleIDCapabilities(bundleIDResourceID: bundleIDResourceID)
        if existing.contains(capabilityType) { return }
        _ = try client.request(method: .post, path: "bundleIdCapabilities", body: [
            "data": [
                "type": "bundleIdCapabilities",
                "attributes": ["capabilityType": capabilityType],
                "relationships": [
                    "bundleId": [
                        "data": ["type": "bundleIds", "id": bundleIDResourceID],
                    ],
                ],
            ],
        ])
    }

    /// Lists capability types currently enabled on a bundle-ID resource.
    public func listBundleIDCapabilities(bundleIDResourceID: String) throws -> [String] {
        let response = try client.request(
            method: .get,
            path: "bundleIds/\(bundleIDResourceID)/bundleIdCapabilities"
        )
        struct Envelope: Decodable {
            struct Data: Decodable {
                struct Attributes: Decodable {
                    let capabilityType: String?
                }
                let attributes: Attributes
            }
            let data: [Data]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.data) else {
            throw ASCError.malformedPayload("bundleIdCapabilities list")
        }
        return envelope.data.compactMap { $0.attributes.capabilityType }
    }

    // MARK: - Devices

    public struct Device: Sendable, Equatable {
        public var id: String
        public var name: String?
        public var udid: String?
        public var platform: String?
        public var status: String?

        public init(id: String, name: String? = nil, udid: String? = nil, platform: String? = nil, status: String? = nil) {
            self.id = id
            self.name = name
            self.udid = udid
            self.platform = platform
            self.status = status
        }
    }

    /// Lists registered iOS-capable devices.
    public func listDevices() throws -> [Device] {
        let response = try client.request(
            method: .get,
            path: "devices",
            query: [URLQueryItem(name: "filter[platform]", value: "IOS")]
        )
        return try Self.decodeDeviceList(response.data)
    }

    /// Decodes a `DevicesResponse` payload.
    public static func decodeDeviceList(_ data: Data) throws -> [Device] {
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable {
                    let name: String?
                    let udid: String?
                    let platform: String?
                    let status: String?
                }
                let attributes: Attributes
            }
            let data: [Data]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload("devices list")
        }
        return envelope.data.map {
            Device(
                id: $0.id,
                name: $0.attributes.name,
                udid: $0.attributes.udid,
                platform: $0.attributes.platform,
                status: $0.attributes.status
            )
        }
    }

    /// Finds the registered device resource for an exact UDID, if any.
    public func findDevice(udid: String) throws -> Device? {
        try listDevices().first { $0.udid == udid }
    }

    /// Registers a physical iOS device. The API returns HTTP 409 when the UDID is
    /// already registered; callers should prefer `getOrRegisterDevice`.
    public func registerDevice(udid: String, name: String) throws -> Device {
        let response = try client.request(method: .post, path: "devices", body: [
            "data": [
                "type": "devices",
                "attributes": [
                    "name": name,
                    "udid": udid,
                    "platform": "IOS",
                ],
            ],
        ])
        return try Self.decodeCreatedDevice(response.data)
    }

    /// Decodes a `DeviceResponse` payload.
    public static func decodeCreatedDevice(_ data: Data) throws -> Device {
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable {
                    let udid: String?
                }
                let attributes: Attributes
            }
            let data: Data
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload("devices create")
        }
        return Device(id: envelope.data.id, udid: envelope.data.attributes.udid)
    }

    /// Registers a device unless the UDID is already registered.
    public func getOrRegisterDevice(udid: String, name: String) throws -> Device {
        if let existing = try findDevice(udid: udid) {
            return existing
        }
        return try registerDevice(udid: udid, name: name)
    }

    // MARK: - Certificates

    public struct Certificate: Sendable {
        public var id: String
        public var certificateContentBase64: String
        public var serialNumber: String?
    }

    /// Fetches certificate resource IDs for an exact certificate type
    /// (e.g. `DISTRIBUTION`, `DEVELOPMENT`).
    public func listCertificateIDs(certificateType: String) throws -> [String] {
        let response = try client.request(
            method: .get,
            path: "certificates",
            query: [URLQueryItem(name: "filter[certificateType]", value: certificateType)]
        )
        let data = response.data
        struct Envelope: Decodable {
            struct Data: Decodable { let id: String }
            let data: [Data]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload("certificates list")
        }
        return envelope.data.map(\.id)
    }

    /// Fetches all distribution certificate IDs.
    public func listDistributionCertificateIDs() throws -> [String] {
        try listCertificateIDs(certificateType: "DISTRIBUTION")
    }

    /// Fetches full certificate resources (ID, serial number, content) for an exact
    /// certificate type. Used to match a locally held identity to its App Store
    /// Connect certificate by content fingerprint.
    public func listCertificates(certificateType: String) throws -> [Certificate] {
        let response = try client.request(
            method: .get,
            path: "certificates",
            query: [URLQueryItem(name: "filter[certificateType]", value: certificateType)]
        )
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable {
                    let certificateContent: String
                    let serialNumber: String?
                }
                let attributes: Attributes
            }
            let data: [Data]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.data) else {
            throw ASCError.malformedPayload("certificates list")
        }
        return envelope.data.map {
            Certificate(
                id: $0.id,
                certificateContentBase64: $0.attributes.certificateContent,
                serialNumber: $0.attributes.serialNumber
            )
        }
    }

    /// Fetches all development certificate IDs.
    public func listDevelopmentCertificateIDs() throws -> [String] {
        try listCertificateIDs(certificateType: "DEVELOPMENT")
    }

    /// Requests a new certificate of the given type from a CSR. Returns the new
    /// certificate resource ID and its PEM content (base64).
    public func createCertificate(csrContent: String, certificateType: String) throws -> Certificate {
        let response = try client.request(method: .post, path: "certificates", body: [
            "data": [
                "type": "certificates",
                "attributes": [
                    "csrContent": csrContent,
                    "certificateType": certificateType,
                ],
            ],
        ])
        let data = response.data
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable {
                    let certificateContent: String
                    let serialNumber: String?
                }
                let attributes: Attributes
            }
            let data: Data
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload("certificates create")
        }
        return Certificate(
            id: envelope.data.id,
            certificateContentBase64: envelope.data.attributes.certificateContent,
            serialNumber: envelope.data.attributes.serialNumber
        )
    }

    /// Requests a new distribution certificate from a CSR.
    public func createDistributionCertificate(csrContent: String) throws -> Certificate {
        try createCertificate(csrContent: csrContent, certificateType: "DISTRIBUTION")
    }

    /// Requests a new development certificate from a CSR.
    public func createDevelopmentCertificate(csrContent: String) throws -> Certificate {
        try createCertificate(csrContent: csrContent, certificateType: "DEVELOPMENT")
    }

    // MARK: - Profiles

    /// Provisioning profile types this project creates.
    public enum ProfileType: String, Sendable {
        case appStore = "IOS_APP_STORE"
        case development = "IOS_APP_DEVELOPMENT"
    }

    /// Fetches the profile resource id for an exact profile name and type, if any.
    public func findProfile(name: String, profileType: ProfileType = .appStore) throws -> String? {
        let response = try client.request(
            method: .get,
            path: "profiles",
            query: [
                URLQueryItem(name: "filter[profileType]", value: profileType.rawValue),
                URLQueryItem(name: "filter[name]", value: name),
            ]
        )
        return try Self.matchProfileID(in: response.data, name: name, profileType: profileType)
    }

    /// Extracts the profile resource ID for an exact name from a `ProfilesResponse`
    /// payload, tolerating the API's substring-ish name filter.
    public static func matchProfileID(in data: Data, name: String, profileType: ProfileType) throws -> String? {
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable {
                    let name: String
                    let profileType: String?
                    let profileState: String
                }
                let attributes: Attributes
            }
            let data: [Data]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload("profiles list")
        }
        return envelope.data.first {
            $0.attributes.name == name && ($0.attributes.profileType == nil || $0.attributes.profileType == profileType.rawValue)
        }?.id
    }

    /// Creates a profile of the given type for one bundle-ID resource, certificate,
    /// and (for development profiles) one or more device resources.
    public func createProfile(
        name: String,
        profileType: ProfileType,
        bundleIDResourceID: String,
        certificateID: String,
        deviceIDs: [String]
    ) throws -> String {
        var body: [String: Any] = [
            "data": [
                "type": "profiles",
                "attributes": [
                    "name": name,
                    "profileType": profileType.rawValue,
                ],
                "relationships": [
                    "bundleId": [
                        "data": ["type": "bundleIds", "id": bundleIDResourceID],
                    ],
                    "certificates": [
                        "data": [["type": "certificates", "id": certificateID]],
                    ],
                ],
            ],
        ]
        if !deviceIDs.isEmpty {
            var data = body["data"] as! [String: Any]
            var relationships = data["relationships"] as! [String: Any]
            relationships["devices"] = [
                "data": deviceIDs.map { ["type": "devices", "id": $0] },
            ]
            data["relationships"] = relationships
            body["data"] = data
        }
        let response = try client.request(method: .post, path: "profiles", body: body)
        return try Self.decodeCreatedResourceID(response.data, resource: "profiles create")
    }

    /// Decodes the `id` from a single-resource `ProfileResponse` payload.
    public static func decodeCreatedResourceID(_ data: Data, resource: String) throws -> String {
        struct Envelope: Decodable {
            struct Data: Decodable { let id: String }
            let data: Data
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload(resource)
        }
        return envelope.data.id
    }

    /// Creates an iOS App Store profile for one bundle-ID resource and certificate.
    public func createAppStoreProfile(name: String, bundleIDResourceID: String, certificateID: String) throws -> String {
        try createProfile(
            name: name,
            profileType: .appStore,
            bundleIDResourceID: bundleIDResourceID,
            certificateID: certificateID,
            deviceIDs: []
        )
    }

    /// Creates a device development profile for one bundle-ID resource, certificate,
    /// and a single device (version 1 intentionally does not attach every device).
    public func createDevelopmentProfile(
        name: String,
        bundleIDResourceID: String,
        certificateID: String,
        deviceID: String
    ) throws -> String {
        try createProfile(
            name: name,
            profileType: .development,
            bundleIDResourceID: bundleIDResourceID,
            certificateID: certificateID,
            deviceIDs: [deviceID]
        )
    }

    /// A lightweight summary of a provisioning profile resource, including its bundle
    /// identifier (from the included `bundleId` relationship).
    public struct ProfileSummary: Sendable, Equatable {
        public var id: String
        public var name: String
        public var profileType: String?
        public var state: String?
        public var expirationDate: Date?
        public var bundleIdentifier: String?

        public init(
            id: String, name: String, profileType: String? = nil, state: String? = nil,
            expirationDate: Date? = nil, bundleIdentifier: String? = nil
        ) {
            self.id = id
            self.name = name
            self.profileType = profileType
            self.state = state
            self.expirationDate = expirationDate
            self.bundleIdentifier = bundleIdentifier
        }
    }

    /// Lists profiles of one type with their bundle identifier resolved from the
    /// included `bundleId` relationship. Used to reconcile existing profiles by bundle
    /// rather than by display name.
    public func listProfiles(profileType: ProfileType) throws -> [ProfileSummary] {
        let response = try client.request(
            method: .get,
            path: "profiles",
            query: [
                URLQueryItem(name: "filter[profileType]", value: profileType.rawValue),
                URLQueryItem(name: "include", value: "bundleId"),
                URLQueryItem(name: "fields[profiles]", value: "name,profileType,profileState,expirationDate"),
                URLQueryItem(name: "fields[bundleIds]", value: "identifier"),
            ]
        )
        return try Self.decodeProfileList(response.data)
    }

    /// Decodes a `ProfilesResponse` with an included `bundleId` relationship into
    /// summaries keyed by bundle expression. Pure for hermetic tests.
    public static func decodeProfileList(_ data: Data) throws -> [ProfileSummary] {
        struct Envelope: Decodable {
            struct Resource: Decodable {
                let id: String
                struct Attributes: Decodable {
                    let name: String
                    let profileType: String?
                    let profileState: String?
                    let expirationDate: Date?
                }
                struct Relationships: Decodable {
                    struct Link: Decodable {
                        struct DataRef: Decodable { let id: String }
                        let data: DataRef?
                    }
                    let bundleId: Link?
                }
                let attributes: Attributes
                let relationships: Relationships?
            }
            struct Included: Decodable {
                let id: String
                let type: String
                struct Attributes: Decodable { let identifier: String? }
                let attributes: Attributes?
            }
            struct RelRef: Decodable {
                struct Data: Decodable { let id: String }
                let data: Data
            }
            let data: [Resource]
            let included: [Included]?
        }
        let json = JSONDecoder()
        json.dateDecodingStrategy = .formatted(Self.ascDateFormatter)
        guard let envelope = try? json.decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload("profiles list")
        }
        let bundleIdentifierByID = Dictionary(
            uniqueKeysWithValues: (envelope.included ?? []).compactMap { (included) -> (String, String)? in
                guard
                    included.type == "bundleIds",
                    let identifier = included.attributes?.identifier
                else { return nil }
                return (included.id, identifier)
            })
        return envelope.data.map { resource in
            let bundleIdentifier: String?
            if let id = resource.relationships?.bundleId?.data?.id {
                bundleIdentifier = bundleIdentifierByID[id]
            } else {
                bundleIdentifier = nil
            }
            return ProfileSummary(
                id: resource.id,
                name: resource.attributes.name,
                profileType: resource.attributes.profileType,
                state: resource.attributes.profileState,
                expirationDate: resource.attributes.expirationDate,
                bundleIdentifier: bundleIdentifier
            )
        }
    }

    /// App Store Connect returns dates as RFC 3339 strings with fractional seconds.
    private static let ascDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// Creates a development profile for a bundle and certificate that provisions the
    /// union of the given device resources. Returns the new profile's id and content.
    public func createDevelopmentProfileUnion(
        name: String,
        bundleIDResourceID: String,
        certificateID: String,
        deviceIDs: [String]
    ) throws -> (id: String, content: Data) {
        let id = try createProfile(
            name: name,
            profileType: .development,
            bundleIDResourceID: bundleIDResourceID,
            certificateID: certificateID,
            deviceIDs: deviceIDs)
        return (id, try downloadProfile(id: id))
    }

    /// Returns the decrypted provisioning profile content for a profile resource.
    public func downloadProfile(id: String) throws -> Data {
        let response = try client.request(method: .get, path: "profiles/\(id)")
        let data = response.data
        struct Envelope: Decodable {
            struct Data: Decodable {
                struct Attributes: Decodable {
                    let profileContent: String
                }
                let attributes: Attributes
            }
            let data: Data
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload("profiles get")
        }
        guard let decoded = Data(base64Encoded: envelope.data.attributes.profileContent) else {
            throw ASCError.malformedPayload("profileContent base64")
        }
        return decoded
    }

    public func deleteProfile(id: String) throws {
        _ = try client.request(method: .delete, path: "profiles/\(id)")
    }

    public enum Error: Swift.Error {}

    /// App Store Connect requires bundle-ID resource names to contain only
    /// alphanumeric characters and spaces. Derive one from the bundle identifier.
    static func displayName(from identifier: String) -> String {
        let cleaned = identifier
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
        return cleaned.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
    }
}