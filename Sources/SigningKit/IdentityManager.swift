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

    /// A certificate and what signs with its key: the stored private key, or a remote
    /// signer holding it (`loadDistribution(remoteSigner:)`).
    public struct SigningIdentity: Sendable {
        public var signer: CMSSigner
        public var certificatePEM: String
        public var certificateID: String?
        public var teamID: String?

        public init(signer: CMSSigner, certificatePEM: String, certificateID: String?, teamID: String?) {
            self.signer = signer
            self.certificatePEM = certificatePEM
            self.certificateID = certificateID
            self.teamID = teamID
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case identityMissing(String)
        case teamIDMissing
        case distributionKeyForOtherCertificate

        public var description: String {
            switch self {
            case let .identityMissing(kind):
                return "No \(kind) identity is stored. Run `stupid-app signing setup` first."
            case .teamIDMissing:
                return "The developer team ID is not stored. Run `stupid-app credentials add` with --team-id."
            case .distributionKeyForOtherCertificate:
                return "A distribution private key is stored for a different certificate. Use a separate --home for the fetched certificate, or remove the stored distribution identity first."
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

    /// Stores the distribution certificate without a private key, for a host that signs
    /// through a release session. Refuses to replace a different certificate while a
    /// distribution key is stored, which would leave that key unusable.
    public func storeDistributionCertificate(
        certificatePEM: String,
        certificateID: String,
        teamID: String
    ) throws {
        let certSecret = Secret.distributionCert.rawValue
        if store.exists(Secret.distributionKey.rawValue), store.exists(certSecret),
           String(decoding: try store.readSecret(certSecret), as: UTF8.self) != certificatePEM {
            throw Error.distributionKeyForOtherCertificate
        }
        try store.writeSecret(certSecret, data: Data(certificatePEM.utf8))
        try store.writeSecret(Secret.distributionCertID.rawValue, data: Data(certificateID.utf8))
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

    /// The stored distribution certificate, signed by `remoteSigner`, which holds its
    /// private key. No private key is read, so none needs to be stored.
    public func loadDistribution(remoteSigner: CMSSigner) throws -> SigningIdentity {
        let certSecret = Secret.distributionCert.rawValue
        guard store.exists(certSecret) else {
            throw Error.identityMissing("distribution certificate")
        }
        return SigningIdentity(
            signer: remoteSigner,
            certificatePEM: String(decoding: try store.readSecret(certSecret), as: UTF8.self),
            certificateID: try readOptional(Secret.distributionCertID.rawValue),
            teamID: try readOptional(Secret.developerTeamID.rawValue)
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
        return SigningIdentity(
            signer: .privateKey(pem: privateKey),
            certificatePEM: certificate,
            certificateID: try readOptional(certIDSecret),
            teamID: try readOptional(Secret.developerTeamID.rawValue)
        )
    }

    private func readOptional(_ secret: String) throws -> String? {
        store.exists(secret) ? String(decoding: try store.readSecret(secret), as: UTF8.self) : nil
    }

    public func teamID() throws -> String {
        guard store.exists(Secret.developerTeamID.rawValue) else {
            throw Error.teamIDMissing
        }
        return String(decoding: try store.readSecret(Secret.developerTeamID.rawValue), as: UTF8.self)
    }
}