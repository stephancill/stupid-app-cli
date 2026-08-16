import ArgumentParser
import Foundation
import ASCKit
import SigningKit

/// `stupid-app signing`: manage signing identities, profiles, and certificate setup.
struct SigningCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "signing",
        abstract: "Manage signing identities and provisioning profiles.",
        subcommands: [SigningSetupCommand.self]
    )
}

/// `stupid-app signing setup`: creates distribution (or development) identities and
/// provisioning profiles through the App Store Connect public API. Gate 1 implements
/// the distribution path; development setup is added in Gate 3.
struct SigningSetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Create or import an Apple signing identity and provisioning profile."
    )

    enum Kind: String, CaseIterable, ExpressibleByArgument {
        case distribution
        case development
    }

    @Option(name: .customLong("kind"), help: "signing kind: distribution (Gate 1) or development (Gate 3).")
    var kind: Kind = .distribution

    @Option(name: .customLong("bundle-id"), help: "Exact bundle identifier to provision.")
    var bundleID: String?

    @Option(name: .customLong("profile-name"), help: "Provisioning profile name prefix (defaults to bundle ID).")
    var profileName: String?

    @Option(name: .customLong("import-key"), help: "Import an existing private key PEM for the distribution identity.")
    var importKeyPath: String?

    @Option(name: .customLong("import-cert"), help: "Import an existing certificate PEM for the distribution identity.")
    var importCertPath: String?

    @Option(name: .customLong("cert-id"), help: "App Store Connect certificate resource ID when importing an existing identity.")
    var importCertID: String?

    @Option(name: .customLong("credential-password"), help: "Credential store passphrase (or STUPID_APP_CREDENTIAL_PASSWORD).")
    var credentialPassword: String?

    @Option(name: .customLong("home"), help: "Credential store directory.")
    var home: String?

    mutating func run() async throws {
        guard kind == .distribution else {
            throw SigningSetupError.unsupported("development signing lands in Gate 3; only --kind distribution is implemented.")
        }

        let env = ProcessInfo.processInfo.environment
        let resolvedPassword = credentialPassword ?? env["STUPID_APP_CREDENTIAL_PASSWORD"]
        guard let resolvedPassword else {
            throw CredentialStore.Error.passphraseUnavailable("signing setup")
        }
        let homeURL = URL(fileURLWithPath: home ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stupid-app/credentials").path)
        let store = CredentialStore(home: homeURL) { resolvedPassword }

        let (apiKey, teamID) = try storedCredentialsOrEnv(resolvedPassword: resolvedPassword)
        let client = ASCClient(jwt: {
            try ASCJWTGenerator(key: apiKey).generate()
        })
        let operations = ASCOperations(client: client)

        guard let bundleID else {
            throw SigningSetupError.bundleIDRequired
        }
        let profileName = self.profileName ?? "\(bundleID) AppStore"

        // 1. Disposable/real explicit bundle ID.
        let bundleResourceID = try operations.getOrCreateBundleID(name: bundleID, identifier: bundleID)
        print("Bundle ID \(bundleID) -> \(bundleResourceID)")

        // 2. Reuse an existing active distribution identity when present, else import
        // or mint one.
        let identityManager = IdentityManager(store: store)
        let importRequested = [importKeyPath, importCertPath, importCertID].filter { $0 != nil }.count
        if importRequested > 0, importRequested != 3 {
            throw SigningSetupError.partialImport
        }
        var identity: IdentityManager.DistributionIdentity
        var certificateID: String
        if store.exists(IdentityManager.Secret.distributionCert.rawValue),
           store.exists(IdentityManager.Secret.distributionKey.rawValue) {
            identity = try identityManager.loadDistribution()
            guard let storedCertID = identity.certificateID, !storedCertID.isEmpty else {
                throw SigningSetupError.storedIdentityMissingCertID
            }
            certificateID = storedCertID
            print("Reusing stored distribution identity (\(certificateID))")
        } else if let importKeyPath, let importCertPath, let importCertID {
            let privateKeyPEM = try String(contentsOf: URL(fileURLWithPath: importKeyPath), encoding: .utf8)
            let certificatePEM = try String(contentsOf: URL(fileURLWithPath: importCertPath), encoding: .utf8)
            try identityManager.storeDistribution(
                privateKeyPEM: privateKeyPEM,
                certificatePEM: certificatePEM,
                certificateID: importCertID,
                teamID: teamID
            )
            certificateID = importCertID
            print("Imported distribution identity \(certificateID)")
        } else {
            let generated = try identityManager.generateKeyAndCSR(
                commonName: "Apple Distribution: \(teamID) (\(teamID))",
                teamID: teamID
            )
            let certificate = try operations.createDistributionCertificate(csrContent: generated.csr)
            certificateID = certificate.id
            let certificatePEM = try decodeCertificate(certificate.certificateContentBase64)
            try identityManager.storeDistribution(
                privateKeyPEM: generated.privateKeyPEM,
                certificatePEM: certificatePEM,
                certificateID: certificateID,
                teamID: teamID
            )
            print("Minted distribution certificate \(certificateID)")
        }

        // 3. Ensure an IOS_APP_STORE profile for the bundle ID + certificate.
        var profileID: String? = try operations.findProfile(name: profileName)
        if let profileID, let content = try? operations.downloadProfile(id: profileID) {
            // Gate 1 accepts an existing profile keyed to the certificate; deeper
            // validation is added in the signing verification step.
            print("Reusing profile \(profileID) (\(profileName))")
            try storeProfile(content, profileName: profileName, home: homeURL)
        } else {
            profileID = try operations.createAppStoreProfile(
                name: profileName,
                bundleIDResourceID: bundleResourceID,
                certificateID: certificateID
            )
            let content = try operations.downloadProfile(id: profileID!)
            try storeProfile(content, profileName: profileName, home: homeURL)
            print("Created profile \(profileID!) (\(profileName))")
        }
        print("Distribution signing setup complete.")
    }

    private func decodeCertificate(_ base64: String) throws -> String {
        let data = try base64Data(base64)
        return "-----BEGIN CERTIFICATE-----\n" +
            data.base64EncodedString(options: [.lineLength64Characters]) +
            "\n-----END CERTIFICATE-----\n"
    }

    private func base64Data(_ base64: String) throws -> Data {
        let normalized = base64
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
        guard let data = Data(base64Encoded: normalized) else {
            throw ASCError.malformedPayload("certificate base64")
        }
        return data
    }

    private func storeProfile(_ data: Data, profileName: String, home: URL) throws {
        let profilesDir = home.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        let url = profilesDir.appendingPathComponent("\(profileName).mobileprovision")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        print("Profile stored at \(url.path)")
    }

    private func storedCredentialsOrEnv(resolvedPassword: String) throws -> (ASCKey, String) {
        let homeURL = URL(fileURLWithPath: home ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stupid-app/credentials").path)
        let store = CredentialStore(home: homeURL) { resolvedPassword }

        // Prefer the encrypted store; fall back to the legacy env-based inputs.
        if let storedTeamID = try? store.loadTeamID(), let storedKey = try? store.loadASCKey() {
            return (storedKey, storedTeamID)
        }

        let env = ProcessInfo.processInfo.environment
        let keyID = env["ASC_API_KEY_ID"]
        let issuerID = env["ASC_API_ISSUER_ID"]
        let p8Path = env["ASC_API_KEY_PATH"]
        let teamID = env["DEVELOPER_TEAM_ID"]
        guard let keyID, let issuerID, let p8Path, let teamID,
              let pem = try? String(contentsOf: URL(fileURLWithPath: p8Path), encoding: .utf8) else {
            throw CredentialStore.Error.passphraseUnavailable("load ASC key")
        }
        return (ASCKey(keyID: keyID, issuerID: issuerID, pem: pem), teamID)
    }
}

enum SigningSetupError: Error, CustomStringConvertible {
    case unsupported(String)
    case bundleIDRequired
    case storedIdentityMissingCertID
    case partialImport

    var description: String {
        switch self {
        case let .unsupported(message):
            return message
        case .bundleIDRequired:
            return "Provide --bundle-id to provision."
        case .storedIdentityMissingCertID:
            return "The stored distribution identity has no certificate ID; delete the stored identity and rerun."
        case .partialImport:
            return "Importing requires all of --import-key, --import-cert, and --cert-id."
        }
    }
}