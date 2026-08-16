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

    // MARK: - Certificates

    public struct Certificate: Sendable {
        public var id: String
        public var certificateContentBase64: String
        public var serialNumber: String?
    }

    /// Fetches all distribution certificates (or their `id`s).
    public func listDistributionCertificateIDs() throws -> [String] {
        let response = try client.request(
            method: .get,
            path: "certificates",
            query: [URLQueryItem(name: "filter[certificateType]", value: "DISTRIBUTION")]
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

    /// Requests a new distribution certificate from a CSR. Returns the new certificate
    /// resource ID and its PEM content (base64).
    public func createDistributionCertificate(csrContent: String) throws -> Certificate {
        let response = try client.request(method: .post, path: "certificates", body: [
            "data": [
                "type": "certificates",
                "attributes": [
                    "csrContent": csrContent,
                    "certificateType": "DISTRIBUTION",
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

    // MARK: - Profiles

    /// Fetches the profile resource id for an exact profile name, if any.
    public func findProfile(name: String) throws -> String? {
        let response = try client.request(
            method: .get,
            path: "profiles",
            query: [
                URLQueryItem(name: "filter[profileType]", value: "IOS_APP_STORE"),
                URLQueryItem(name: "filter[name]", value: name),
            ]
        )
        let data = response.data
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable {
                    let name: String
                    let profileState: String
                }
                let attributes: Attributes
            }
            let data: [Data]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload("profiles list")
        }
        return envelope.data.first { $0.attributes.name == name }?.id
    }

    /// Creates an iOS App Store profile for one bundle-ID resource and certificate.
    public func createAppStoreProfile(name: String, bundleIDResourceID: String, certificateID: String) throws -> String {
        let response = try client.request(method: .post, path: "profiles", body: [
            "data": [
                "type": "profiles",
                "attributes": [
                    "name": name,
                    "profileType": "IOS_APP_STORE",
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
        ])
        let data = response.data
        struct Envelope: Decodable {
            struct Data: Decodable { let id: String }
            let data: Data
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload("profiles create")
        }
        return envelope.data.id
    }

    /// Downloads the decrypted provisioning profile content for a profile resource.
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