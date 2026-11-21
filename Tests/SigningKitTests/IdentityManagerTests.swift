import Foundation
import Testing
@testable import ASCKit
@testable import SigningKit

/// Unit tests for signing-identity storage using a temporary credential store.
/// No real keys, certificates, or credentials are used.
struct IdentityManagerTests {
    /// Creates an isolated store in a temp directory.
    private func makeManager() throws -> (manager: IdentityManager, store: CredentialStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-identity-test-\(UUID().uuidString)", isDirectory: true)
        let store = CredentialStore(home: dir)
        return (IdentityManager(store: store), store)
    }

    @Test("development identity round-trips through the credential store")
    func developmentRoundTrip() throws {
        let (manager, store) = try makeManager()
        defer { try? FileManager.default.removeItem(at: store.home) }

        try manager.storeDevelopment(
            privateKeyPEM: "-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----\n",
            certificatePEM: "-----BEGIN CERTIFICATE-----\ncert\n-----END CERTIFICATE-----\n",
            certificateID: "dev-cert-1",
            teamID: "TEAMID1234"
        )

        let loaded = try manager.loadDevelopment()
        #expect(loaded.certificateID == "dev-cert-1")
        #expect(loaded.teamID == "TEAMID1234")
        #expect(loaded.certificatePEM.contains("BEGIN CERTIFICATE"))
    }

    @Test("development and distribution identities are stored separately")
    func identitiesAreSeparate() throws {
        let (manager, store) = try makeManager()
        defer { try? FileManager.default.removeItem(at: store.home) }

        try manager.storeDevelopment(
            privateKeyPEM: "dev-key", certificatePEM: "dev-cert", certificateID: "dev-1", teamID: "TEAMID1234"
        )
        try manager.storeDistribution(
            privateKeyPEM: "dist-key", certificatePEM: "dist-cert", certificateID: "dist-1", teamID: "TEAMID1234"
        )

        let development = try manager.loadDevelopment()
        let distribution = try manager.loadDistribution()
        #expect(development.certificateID == "dev-1")
        #expect(distribution.certificateID == "dist-1")
    }

    @Test("a remotely signed distribution identity needs only the stored certificate")
    func remoteDistributionIdentity() throws {
        let (manager, store) = try makeManager()
        defer { try? FileManager.default.removeItem(at: store.home) }

        try manager.storeDistributionCertificate(
            certificatePEM: "dist-cert", certificateID: "dist-1", teamID: "TEAMID1234")
        #expect(!store.exists(IdentityManager.Secret.distributionKey.rawValue))
        #expect(throws: IdentityManager.Error.self) { _ = try manager.loadDistribution() }

        let remote = CMSSigner { _ in Data([1, 2, 3]) }
        let identity = try manager.loadDistribution(remoteSigner: remote)
        #expect(identity.certificatePEM == "dist-cert")
        #expect(identity.certificateID == "dist-1")
        #expect(identity.teamID == "TEAMID1234")
        let request = CMSSignRequest(codeDirectory: Data(), signedAttributes: Data())
        #expect(try identity.signer.sign(request) == Data([1, 2, 3]))
    }

    @Test("a fetched certificate never replaces one whose key is stored")
    func fetchedCertificateKeepsStoredKeyUsable() throws {
        let (manager, store) = try makeManager()
        defer { try? FileManager.default.removeItem(at: store.home) }

        try manager.storeDistribution(
            privateKeyPEM: "dist-key", certificatePEM: "dist-cert", certificateID: "dist-1", teamID: "TEAMID1234")
        try manager.storeDistributionCertificate(
            certificatePEM: "dist-cert", certificateID: "dist-1", teamID: "TEAMID1234")
        #expect(throws: IdentityManager.Error.distributionKeyForOtherCertificate) {
            try manager.storeDistributionCertificate(
                certificatePEM: "other-cert", certificateID: "dist-2", teamID: "TEAMID1234")
        }
        #expect(try manager.loadDistribution().certificatePEM == "dist-cert")
    }

    @Test("loading a missing development identity fails loudly")
    func missingDevelopmentIdentity() throws {
        let (manager, store) = try makeManager()
        defer { try? FileManager.default.removeItem(at: store.home) }

        #expect(throws: IdentityManager.Error.self) {
            _ = try manager.loadDevelopment()
        }
    }
}
