import Crypto
import Foundation
import ASCKit
import X509
import _CryptoExtras

/// Generates and persists Apple signing identities (development/distribution private
/// keys and certificates). Private keys are stored through the encrypted credential
/// store; the certificate chain is stored as PEM.
public struct IdentityManager {
    public var store: CredentialStore

    public init(store: CredentialStore) {
        self.store = store
    }

    public enum Secret: String {
        case developmentKey = "development.key.pem"
        case developmentCert = "development.cert.pem"
        case distributionKey = "distribution.key.pem"
        case distributionCert = "distribution.cert.pem"
        case distributionCertID = "distribution.cert.id"
        case developerTeamID = "developer-team-id"
    }

    public struct DistributionIdentity {
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
    public func storeDistribution(
        privateKeyPEM: String,
        certificatePEM: String,
        certificateID: String,
        teamID: String
    ) throws {
        try store.writeSecret(Secret.distributionKey.rawValue, data: Data(privateKeyPEM.utf8))
        try store.writeSecret(Secret.distributionCert.rawValue, data: Data(certificatePEM.utf8))
        try store.writeSecret(Secret.distributionCertID.rawValue, data: Data(certificateID.utf8))
        try store.writeSecret(Secret.developerTeamID.rawValue, data: Data(teamID.utf8))
    }

    public func loadDistribution() throws -> DistributionIdentity {
        guard store.exists(Secret.distributionKey.rawValue),
              store.exists(Secret.distributionCert.rawValue) else {
            throw Error.identityMissing("distribution")
        }
        let privateKey = String(decoding: try store.readSecret(Secret.distributionKey.rawValue), as: UTF8.self)
        let certificate = String(decoding: try store.readSecret(Secret.distributionCert.rawValue), as: UTF8.self)
        let certificateID = store.exists(Secret.distributionCertID.rawValue)
            ? String(decoding: try store.readSecret(Secret.distributionCertID.rawValue), as: UTF8.self)
            : nil
        let teamID = store.exists(Secret.developerTeamID.rawValue)
            ? String(decoding: try store.readSecret(Secret.developerTeamID.rawValue), as: UTF8.self)
            : nil
        return DistributionIdentity(
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