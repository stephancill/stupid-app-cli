import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - TestFlight models

/// An App Store Connect beta group (external or internal).
public struct ASCBetaGroup: Sendable, Equatable {
    public var id: String
    public var name: String
    public var isInternalGroup: Bool?

    public init(id: String, name: String, isInternalGroup: Bool? = nil) {
        self.id = id
        self.name = name
        self.isInternalGroup = isInternalGroup
    }
}

/// A `betaAppReviewSubmissions` resource — one row per external-beta submission.
public struct ASCBetaAppReviewSubmission: Sendable, Equatable {
    public var id: String
    /// `WAITING_FOR_REVIEW`, `IN_REVIEW`, `BETA_APPROVED`, `BETA_REJECTED`, …
    public var state: String?

    public init(id: String, state: String? = nil) {
        self.id = id
        self.state = state
    }
}

/// A `betaBuildLocalizations` row carrying the per-build "What to Test" note.
public struct ASCBetaBuildLocalization: Sendable, Equatable {
    public var id: String
    public var locale: String?
    public var whatsNew: String?

    public init(id: String, locale: String? = nil, whatsNew: String? = nil) {
        self.id = id
        self.locale = locale
        self.whatsNew = whatsNew
    }
}

/// A minimal beta tester record for external-group invitations.
public struct ASCBetaTester: Sendable, Equatable {
    public var id: String
    public var email: String?
    public var firstName: String?
    public var lastName: String?

    public init(id: String, email: String? = nil, firstName: String? = nil, lastName: String? = nil) {
        self.id = id
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
    }
}

// MARK: - Operations

public extension ASCOperations {

    /// Lists the beta groups for an app.
    func listBetaGroups(appID: String) throws -> [ASCBetaGroup] {
        let response = try client.request(
            method: .get,
            path: "betaGroups",
            query: [
                URLQueryItem(name: "filter[app]", value: appID),
                URLQueryItem(name: "limit", value: "200"),
            ]
        )
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable {
                    let name: String?
                    let isInternalGroup: Bool?
                }
                let attributes: Attributes
            }
            let data: [Data]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.data) else {
            throw ASCError.malformedPayload("betaGroups list")
        }
        return envelope.data.map {
            ASCBetaGroup(id: $0.id, name: $0.attributes.name ?? "", isInternalGroup: $0.attributes.isInternalGroup)
        }
    }

    /// Finds an external beta group by exact name for an app.
    func findBetaGroup(appID: String, name: String) throws -> ASCBetaGroup? {
        try listBetaGroups(appID: appID).first { $0.name == name }
    }

    /// Creates a beta group for an app. External groups are created with
    /// `isInternalGroup = false`.
    func createBetaGroup(name: String, appID: String, isInternalGroup: Bool = false) throws -> ASCBetaGroup {
        let response = try client.request(
            method: .post,
            path: "betaGroups",
            body: [
                "data": [
                    "type": "betaGroups",
                    "attributes": [
                        "name": name,
                        "isInternalGroup": isInternalGroup,
                    ],
                    "relationships": [
                        "app": ["data": ["type": "apps", "id": appID]],
                    ],
                ],
            ]
        )
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable { let name: String?; let isInternalGroup: Bool? }
                let attributes: Attributes
            }
            let data: Data
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.data) else {
            throw ASCError.malformedPayload("betaGroups create")
        }
        return ASCBetaGroup(
            id: envelope.data.id,
            name: envelope.data.attributes.name ?? name,
            isInternalGroup: envelope.data.attributes.isInternalGroup ?? isInternalGroup)
    }

    /// Adds a build to a beta group (external distribution).
    func addBuild(betaGroupID: String, buildID: String) throws {
        _ = try client.request(
            method: .post,
            path: "betaGroups/\(betaGroupID)/relationships/builds",
            body: ["data": [["type": "builds", "id": buildID]]]
        )
    }

    /// Finds a beta tester by email, or nil.
    func findBetaTester(appID: String, email: String) throws -> ASCBetaTester? {
        let response = try client.request(
            method: .get,
            path: "betaTesters",
            query: [
                URLQueryItem(name: "filter[apps]", value: appID),
                URLQueryItem(name: "filter[email]", value: email),
                URLQueryItem(name: "limit", value: "200"),
            ]
        )
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable {
                    let email: String?
                    let firstName: String?
                    let lastName: String?
                }
                let attributes: Attributes
            }
            let data: [Data]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.data) else {
            throw ASCError.malformedPayload("betaTesters lookup")
        }
        return envelope.data.first.map {
            ASCBetaTester(
                id: $0.id,
                email: $0.attributes.email ?? email,
                firstName: $0.attributes.firstName,
                lastName: $0.attributes.lastName)
        }
    }

    /// Creates a beta tester and returns its resource ID.
    func createBetaTester(email: String, firstName: String?, lastName: String?) throws -> String {
        var attributes: [String: Any] = ["email": email]
        if let firstName { attributes["firstName"] = firstName }
        if let lastName { attributes["lastName"] = lastName }
        let response = try client.request(
            method: .post,
            path: "betaTesters",
            body: ["data": ["type": "betaTesters", "attributes": attributes]]
        )
        struct Envelope: Decodable { struct Data: Decodable { let id: String }; let data: Data }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.data) else {
            throw ASCError.malformedPayload("betaTesters create")
        }
        return envelope.data.id
    }

    /// Adds testers to a beta group.
    func addBetaTesters(betaGroupID: String, testerIDs: [String]) throws {
        guard !testerIDs.isEmpty else { return }
        _ = try client.request(
            method: .post,
            path: "betaGroups/\(betaGroupID)/relationships/betaTesters",
            body: ["data": testerIDs.map { ["type": "betaTesters", "id": $0] }]
        )
    }

    /// Creates an external beta review submission for a build in a beta group. Returns
    /// the submission id.
    func createBetaAppReviewSubmission(buildID: String, betaGroupID: String) throws -> String {
        let response = try client.request(
            method: .post,
            path: "betaAppReviewSubmissions",
            body: [
                "data": [
                    "type": "betaAppReviewSubmissions",
                    "relationships": [
                        "build": ["data": ["type": "builds", "id": buildID]],
                        "betaGroup": ["data": ["type": "betaGroups", "id": betaGroupID]],
                    ],
                ],
            ]
        )
        struct Envelope: Decodable { struct Data: Decodable { let id: String }; let data: Data }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.data) else {
            throw ASCError.malformedPayload("betaAppReviewSubmissions create")
        }
        return envelope.data.id
    }

    /// Fetches a beta review submission by id.
    func getBetaAppReviewSubmission(id: String) throws -> ASCBetaAppReviewSubmission {
        let response = try client.request(method: .get, path: "betaAppReviewSubmissions/\(id)")
        return try Self.decodeBetaAppReviewSubmission(response.data)
    }

    /// Returns the most recently created beta review submission for a build, if any.
    func findLatestBetaAppReviewSubmission(buildID: String) throws -> ASCBetaAppReviewSubmission? {
        let response = try client.request(
            method: .get,
            path: "betaAppReviewSubmissions",
            query: [
                URLQueryItem(name: "filter[build]", value: buildID),
                URLQueryItem(name: "sort", value: "-createdDate"),
                URLQueryItem(name: "limit", value: "1"),
            ]
        )
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable { let state: String?; let submissionState: String? }
                let attributes: Attributes
            }
            let data: [Data]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.data) else {
            throw ASCError.malformedPayload("betaAppReviewSubmissions lookup")
        }
        guard let first = envelope.data.first else { return nil }
        return ASCBetaAppReviewSubmission(
            id: first.id, state: first.attributes.submissionState ?? first.attributes.state)
    }

    /// Lists `betaBuildLocalizations` for a build.
    func listBetaBuildLocalizations(buildID: String) throws -> [ASCBetaBuildLocalization] {
        let response = try client.request(
            method: .get, path: "betaBuildLocalizations",
            query: [URLQueryItem(name: "filter[build]", value: buildID)])
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable { let locale: String?; let whatsNew: String? }
                let attributes: Attributes
            }
            let data: [Data]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: response.data) else {
            throw ASCError.malformedPayload("betaBuildLocalizations list")
        }
        return envelope.data.map {
            ASCBetaBuildLocalization(id: $0.id, locale: $0.attributes.locale, whatsNew: $0.attributes.whatsNew)
        }
    }

    /// Sets the "What to Test" note on a build, creating the localization row if needed.
    /// Returns the localization id.
    func setWhatsNew(buildID: String, whatsNew: String, locale: String = "en-US") throws -> String {
        if let existing = try listBetaBuildLocalizations(buildID: buildID).first {
            _ = try client.request(
                method: .patch,
                path: "betaBuildLocalizations/\(existing.id)",
                body: [
                    "data": [
                        "type": "betaBuildLocalizations",
                        "id": existing.id,
                        "attributes": ["whatsNew": whatsNew],
                    ]
                ]
            )
            return existing.id
        }
        let response = try client.request(
            method: .post,
            path: "betaBuildLocalizations",
            body: [
                "data": [
                    "type": "betaBuildLocalizations",
                    "attributes": ["whatsNew": whatsNew, "locale": locale],
                    "relationships": [
                        "build": ["data": ["type": "builds", "id": buildID]]
                    ],
                ]
            ]
        )
        return try Self.decodeBetaResourceID(response.data, resource: "betaBuildLocalizations create")
    }

    // MARK: - Decoding

    static func decodeBetaAppReviewSubmission(_ data: Data) throws -> ASCBetaAppReviewSubmission {
        struct Envelope: Decodable {
            struct Data: Decodable {
                let id: String
                struct Attributes: Decodable { let submissionState: String?; let state: String? }
                let attributes: Attributes
            }
            let data: Data
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload("betaAppReviewSubmissions get")
        }
        return ASCBetaAppReviewSubmission(
            id: envelope.data.id,
            state: envelope.data.attributes.submissionState ?? envelope.data.attributes.state)
    }

    static func decodeBetaResourceID(_ data: Data, resource: String) throws -> String {
        struct Envelope: Decodable { struct Data: Decodable { let id: String }; let data: Data }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ASCError.malformedPayload(resource)
        }
        return envelope.data.id
    }

    // MARK: - Pure state decisions (credential-free, unit-testable)

    /// Classifies an external beta review submission into a decision.
    enum ExternalReviewDecision: Equatable, Sendable {
        case keepPolling
        case approved
        case rejected(String)
    }

    static func externalReviewDecision(_ state: String?) -> ExternalReviewDecision {
        switch state {
        case "BETA_APPROVED", "IN_BETA_TESTING":
            return .approved
        case "BETA_REJECTED", "REJECTED":
            return .rejected(state ?? "REJECTED")
        case .none, "", "WAITING_FOR_APP_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "PROCESSING":
            return .keepPolling
        default:
            return .rejected(state ?? "unknown")
        }
    }

    /// Classifies the build's external TestFlight readiness state.
    enum ExternalBetaState: Equatable, Sendable {
        case ready
        case keepPolling
        case terminal(String)
    }

    static func externalBetaDecision(_ state: String?) -> ExternalBetaState {
        switch state {
        case "IN_BETA_TESTING", "READY_FOR_BETA_TESTING":
            return .ready
        case "PROCESSING_EXCEPTION", "EXPIRED", "MISSING_EXPORT_COMPLIANCE":
            return .terminal(state ?? "unknown")
        case .none, "", "PROCESSING":
            return .keepPolling
        default:
            return .terminal(state ?? "unknown")
        }
    }
}