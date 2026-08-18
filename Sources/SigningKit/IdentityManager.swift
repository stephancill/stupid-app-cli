import Crypto
import Foundation
import ASCKit
import X509
import _CryptoExtras

/// Generates and persists Apple signing identities (development/distribution private
/// keys and certificates). Private keys are stored through the permission-hardened
/// credential store; the certificate chain is stored as PEM.
public struct IdentityManager {
    public var store: CredentialStore

    public init(store: CredentialStore) {
        self.store = store
    }

    public enum Secret: String {
        case developmentKey = "development.key.pem"
        case developmentCert = "development.cert.pem"
        case developmentCertID = "development.cert.id"
        case distributionKey = "distribution.key.pem"
        case distributionCert = "distribution.cert.pem"
        case distributionCertID = "distribution.cert.id"
        case developerTeamID = "developer-team-id"
    }

    public struct SigningIdentity: Sendable {
        public var privateKeyPEM: String
        public var certificatePEM: String
        public var certificateID: String?
        public var teamID: String?

        public init(privateKeyPEM: String, certificatePEM: String, certificateID: String?, teamID: String?) {
            self.privateKeyPEM = privateKeyPEM
            self.certificatePEM = certificatePEM
            self.certificateID = certificateID
            self.teamID = teamID
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case identityMissing(String)
        case teamIDMissing

        public var description: String {
            switch self {
            case let .identityMissing(kind):
                return "No \(kind) identity is stored. Run `stupid-app signing setup` first."
            case .teamIDMissing:
                return "The developer team ID is not stored. Run `stupid-app credentials add` with --team-id."
            }
        }
    }

    /// Generates a fresh RSA-2048 signing key for the given purpose and returns the
    /// PEM form plus a CSR for certificate issuance.
    public func generateKeyAndCSR(commonName: String, teamID: String) throws -> (privateKeyPEM: String, csr: String) {
        let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let request = try CertificateSigningRequest(
            version: .v1,
            subject: DistinguishedName {
                CountryName("US")
                OrganizationName(teamID)
                CommonName(commonName)
            },
            privateKey: .init(key),
            attributes: CertificateSigningRequest.Attributes(),
            signatureAlgorithm: .sha256WithRSAEncryption
        )
        return (
            privateKeyPEM: key.pkcs8PEMRepresentation,
            csr: try request.serializeAsPEM().pemString
        )
    }

    /// Stores a generated or imported private key and certificate pair for a purpose.
    /// `certificateID` may be nil when no App Store Connect identity is resolvable;
    /// the stored identity then supports local build/run/release-archive only.
    public func storeDistribution(
        privateKeyPEM: String,
        certificatePEM: String,
        certificateID: String?,
        teamID: String
    ) throws {
        try store.writeSecret(Secret.distributionKey.rawValue, data: Data(privateKeyPEM.utf8))
        try store.writeSecret(Secret.distributionCert.rawValue, data: Data(certificatePEM.utf8))
        if let certificateID {
            try store.writeSecret(Secret.distributionCertID.rawValue, data: Data(certificateID.utf8))
        } else {
            try? FileManager.default.removeItem(at: store.fileURL(forSecret: Secret.distributionCertID.rawValue))
        }
        try store.writeSecret(Secret.developerTeamID.rawValue, data: Data(teamID.utf8))
    }

    public func loadDistribution() throws -> SigningIdentity {
        try load(
            keySecret: Secret.distributionKey.rawValue,
            certSecret: Secret.distributionCert.rawValue,
            certIDSecret: Secret.distributionCertID.rawValue,
            kind: "distribution"
        )
    }

    /// Stores a development identity (private key + certificate + optional certificate ID).
    public func storeDevelopment(
        privateKeyPEM: String,
        certificatePEM: String,
        certificateID: String?,
        teamID: String
    ) throws {
        try store.writeSecret(Secret.developmentKey.rawValue, data: Data(privateKeyPEM.utf8))
        try store.writeSecret(Secret.developmentCert.rawValue, data: Data(certificatePEM.utf8))
        if let certificateID {
            try store.writeSecret(Secret.developmentCertID.rawValue, data: Data(certificateID.utf8))
        } else {
            try? FileManager.default.removeItem(at: store.fileURL(forSecret: Secret.developmentCertID.rawValue))
        }
        try store.writeSecret(Secret.developerTeamID.rawValue, data: Data(teamID.utf8))
    }

    public func loadDevelopment() throws -> SigningIdentity {
        try load(
            keySecret: Secret.developmentKey.rawValue,
            certSecret: Secret.developmentCert.rawValue,
            certIDSecret: Secret.developmentCertID.rawValue,
            kind: "development"
        )
    }

    private func load(keySecret: String, certSecret: String, certIDSecret: String, kind: String) throws -> SigningIdentity {
        guard store.exists(keySecret), store.exists(certSecret) else {
            throw Error.identityMissing(kind)
        }
        let privateKey = String(decoding: try store.readSecret(keySecret), as: UTF8.self)
        let certificate = String(decoding: try store.readSecret(certSecret), as: UTF8.self)
        let certificateID = store.exists(certIDSecret)
            ? String(decoding: try store.readSecret(certIDSecret), as: UTF8.self)
            : nil
        let teamID = store.exists(Secret.developerTeamID.rawValue)
            ? String(decoding: try store.readSecret(Secret.developerTeamID.rawValue), as: UTF8.self)
            : nil
        return SigningIdentity(
            privateKeyPEM: privateKey,
            certificatePEM: certificate,
            certificateID: certificateID,
            teamID: teamID
        )
    }

    public func teamID() throws -> String {
        guard store.exists(Secret.developerTeamID.rawValue) else {
            throw Error.teamIDMissing
        }
        return String(decoding: try store.readSecret(Secret.developerTeamID.rawValue), as: UTF8.self)
    }
}