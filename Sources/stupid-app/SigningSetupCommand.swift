import ArgumentParser
import Crypto
import Foundation
import ASCKit
import ProjectCore
import SigningKit

/// `stupid-app signing`: manage signing identities, profiles, and certificate setup.
struct SigningCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "signing",
        abstract: "Manage signing identities and provisioning profiles.",
        subcommands: [SigningSetupCommand.self]
    )
}

/// `stupid-app signing setup`: one-stop credential and signing bootstrap. Creates or
/// imports distribution and development identities and provisioning profiles through
/// the App Store Connect public API, and optionally stores credentials and reuses
/// Xcode-managed identities.
struct SigningSetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Bootstrap credentials and provisioning from a single App Store Connect key."
    )

    enum Kind: String, CaseIterable, ExpressibleByArgument {
        case distribution
        case development
    }

    @Option(name: .customLong("kind"), help: "Signing kind to provision (repeatable; defaults to both distribution and development).")
    var kinds: [Kind] = []

    @Option(name: .customLong("bundle-id"), help: "Exact bundle identifier to provision (repeatable).")
    var bundleIDs: [String] = []

    @Option(name: .customLong("profile-name"), help: "Provisioning profile name prefix (defaults to bundle ID).")
    var profileName: String?

    @Option(name: .customLong("udid"), help: "Physical device UDID (development setup).")
    var deviceUDID: String?

    @Option(name: .customLong("device-name"), help: "Device display name used when registering (development setup).")
    var deviceName: String?

    @Option(name: .customLong("import-key"), help: "Import an existing private key PEM for the identity.")
    var importKeyPath: String?

    @Option(name: .customLong("import-cert"), help: "Import an existing certificate PEM for the identity.")
    var importCertPath: String?

    @Option(name: .customLong("cert-id"), help: "App Store Connect certificate resource ID when importing an existing identity.")
    var importCertID: String?

    @Flag(name: .customLong("from-xcode"), help: "Reuse an existing signing identity and profile already managed by Xcode (macOS only).")
    var fromXcode: Bool = false

    @Option(name: .customLong("key-id"), help: "App Store Connect API key ID (stored when provided).")
    var keyID: String?

    @Option(name: .customLong("issuer-id"), help: "App Store Connect issuer ID (stored when provided).")
    var issuerID: String?

    @Option(name: .customLong("p8"), help: "Path to the App Store Connect .p8 API key file (stored when provided).")
    var p8Path: String?

    @Option(name: .customLong("team-id"), help: "Apple Developer Team ID (stored when provided).")
    var teamID: String?

    @Option(name: .customLong("home"), help: "Credential store directory.")
    var home: String?

    mutating func run() async throws {
        // Store the App Store Connect key and team ID when supplied, so a fresh user
        // needs no separate `credentials add`.
        if keyID != nil || issuerID != nil || p8Path != nil {
            var credentials = CredentialsAddCommand()
            credentials.keyID = keyID
            credentials.issuerID = issuerID
            credentials.p8Path = p8Path
            credentials.teamID = teamID
            credentials.home = home
            try await credentials.run()
        }

        let effectiveKinds = kinds.isEmpty ? [Kind.distribution, Kind.development] : kinds
        let bundles = try resolveBundleIDs()
        guard !bundles.isEmpty else {
            throw SigningSetupError.bundleIDRequired
        }

        let importRequested = [importKeyPath, importCertPath, importCertID].filter { $0 != nil }.count
        if importRequested > 0, importRequested != 3 {
            throw SigningSetupError.partialImport
        }

        if fromXcode {
            let context = try optionalASCContext()
            for kind in effectiveKinds {
                for bundleID in bundles {
                    try runFromXcode(kind: kind, bundleID: bundleID, context: context)
                }
            }
            return
        }

        let context = try ASCContext.resolve(home: home, purpose: "signing setup")
        let operations = context.operations()
        let identityManager = IdentityManager(store: context.credentialStore)

        for kind in effectiveKinds {
            for bundleID in bundles {
                switch kind {
                case .distribution:
                    try runDistribution(
                        operations: operations,
                        identityManager: identityManager,
                        context: context,
                        bundleID: bundleID
                    )
                case .development:
                    guard let deviceUDID else {
                        print("Skipped development setup for \(bundleID): provide --udid to register a device.")
                        continue
                    }
                    try runDevelopment(
                        operations: operations,
                        identityManager: identityManager,
                        context: context,
                        bundleID: bundleID,
                        deviceUDID: deviceUDID
                    )
                }
            }
        }
    }

    // MARK: - Distribution

    private func runDistribution(
        operations: ASCOperations,
        identityManager: IdentityManager,
        context: ASCContext,
        bundleID: String
    ) throws {
        // 1. Disposable/real explicit bundle ID.
        let bundleResourceID = try operations.getOrCreateBundleID(name: bundleID, identifier: bundleID)
        print("Bundle ID \(bundleID) -> \(bundleResourceID)")

        // 2. Reuse an existing active distribution identity when present, else import
        // or mint one.
        var identity: IdentityManager.SigningIdentity
        var certificateID: String
        if context.credentialStore.exists(IdentityManager.Secret.distributionCert.rawValue),
           context.credentialStore.exists(IdentityManager.Secret.distributionKey.rawValue) {
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
                teamID: context.teamID
            )
            certificateID = importCertID
            print("Imported distribution identity \(certificateID)")
        } else {
            let generated = try identityManager.generateKeyAndCSR(
                commonName: "Apple Distribution: \(context.teamID) (\(context.teamID))",
                teamID: context.teamID
            )
            let certificate = try operations.createDistributionCertificate(csrContent: generated.csr)
            certificateID = certificate.id
            let certificatePEM = try decodeCertificate(certificate.certificateContentBase64)
            try identityManager.storeDistribution(
                privateKeyPEM: generated.privateKeyPEM,
                certificatePEM: certificatePEM,
                certificateID: certificateID,
                teamID: context.teamID
            )
            print("Minted distribution certificate \(certificateID)")
        }

        // 3. Ensure an IOS_APP_STORE profile for the bundle ID + certificate.
        let profileName = self.profileName ?? "\(bundleID) AppStore"
        var profileID: String? = try operations.findProfile(name: profileName)
        if let profileID, let content = try? operations.downloadProfile(id: profileID) {
            // Gate 1 accepts an existing profile keyed to the certificate; deeper
            // validation is added in the signing verification step.
            print("Reusing profile \(profileID) (\(profileName))")
            try storeProfile(content, profileName: profileName, home: context.homeURL)
        } else {
            profileID = try operations.createAppStoreProfile(
                name: profileName,
                bundleIDResourceID: bundleResourceID,
                certificateID: certificateID
            )
            let content = try operations.downloadProfile(id: profileID!)
            try storeProfile(content, profileName: profileName, home: context.homeURL)
            print("Created profile \(profileID!) (\(profileName))")
        }
        print("Distribution signing setup complete.")
    }

    // MARK: - Development

    private func runDevelopment(
        operations: ASCOperations,
        identityManager: IdentityManager,
        context: ASCContext,
        bundleID: String,
        deviceUDID: String
    ) throws {
        // 1. Bundle ID and physical device.
        let bundleResourceID = try operations.getOrCreateBundleID(name: bundleID, identifier: bundleID)
        print("Bundle ID \(bundleID) -> \(bundleResourceID)")

        let device = try operations.getOrRegisterDevice(udid: deviceUDID, name: deviceName ?? "iPhone")
        print("Device \(device.id) (\(device.udid ?? deviceUDID))")

        // 2. Reuse an existing active development identity when present, else import
        // or mint one.
        var identity: IdentityManager.SigningIdentity
        var certificateID: String
        if context.credentialStore.exists(IdentityManager.Secret.developmentCert.rawValue),
           context.credentialStore.exists(IdentityManager.Secret.developmentKey.rawValue) {
            identity = try identityManager.loadDevelopment()
            guard let storedCertID = identity.certificateID, !storedCertID.isEmpty else {
                throw SigningSetupError.storedIdentityMissingCertID
            }
            certificateID = storedCertID
            print("Reusing stored development identity (\(certificateID))")
        } else if let importKeyPath, let importCertPath, let importCertID {
            let privateKeyPEM = try String(contentsOf: URL(fileURLWithPath: importKeyPath), encoding: .utf8)
            let certificatePEM = try String(contentsOf: URL(fileURLWithPath: importCertPath), encoding: .utf8)
            try identityManager.storeDevelopment(
                privateKeyPEM: privateKeyPEM,
                certificatePEM: certificatePEM,
                certificateID: importCertID,
                teamID: context.teamID
            )
            certificateID = importCertID
            print("Imported development identity \(certificateID)")
        } else {
            let generated = try identityManager.generateKeyAndCSR(
                commonName: "Apple Development: \(context.teamID) (\(context.teamID))",
                teamID: context.teamID
            )
            let certificate = try operations.createDevelopmentCertificate(csrContent: generated.csr)
            certificateID = certificate.id
            let certificatePEM = try decodeCertificate(certificate.certificateContentBase64)
            try identityManager.storeDevelopment(
                privateKeyPEM: generated.privateKeyPEM,
                certificatePEM: certificatePEM,
                certificateID: certificateID,
                teamID: context.teamID
            )
            print("Minted development certificate \(certificateID)")
        }

        // 3. Ensure an IOS_APP_DEVELOPMENT profile for the bundle ID + certificate +
        // the selected device only (version 1 does not attach every device).
        let profileName = self.profileName ?? "\(bundleID) Development"
        var profileID: String? = try operations.findProfile(name: profileName, profileType: .development)
        if let profileID, let content = try? operations.downloadProfile(id: profileID) {
            print("Reusing profile \(profileID) (\(profileName))")
            try storeProfile(content, profileName: profileName, home: context.homeURL)
        } else {
            profileID = try operations.createDevelopmentProfile(
                name: profileName,
                bundleIDResourceID: bundleResourceID,
                certificateID: certificateID,
                deviceID: device.id
            )
            let content = try operations.downloadProfile(id: profileID!)
            try storeProfile(content, profileName: profileName, home: context.homeURL)
            print("Created profile \(profileID!) (\(profileName))")
        }
        print("Development signing setup complete.")
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

    // MARK: - Xcode credential reuse

    /// Returns the explicitly-supplied bundle IDs, or the bundle ID from a
    /// `stupid-app.yml` present in the current directory when none were supplied.
    private func resolveBundleIDs() throws -> [String] {
        if !bundleIDs.isEmpty { return bundleIDs }
        let configURL = URL(fileURLWithPath: "stupid-app.yml")
        guard let data = try? Data(contentsOf: configURL) else { return [] }
        let config = try AppConfig.decode(data)
        return [config.bundleID]
    }

    private func optionalASCContext() throws -> ASCContext? {
        let homePath = home ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stupid-app/credentials").path
        let store = CredentialStore(home: URL(fileURLWithPath: homePath))
        guard let teamID = try? store.loadTeamID(), let key = try? store.loadASCKey() else { return nil }
        return ASCContext(apiKey: key, teamID: teamID, homeURL: store.home, credentialStore: store)
    }

    /// Imports an existing identity and exact provisioning profile for a kind and
    /// bundle from the user's Xcode-managed Keychain and profile folder (macOS only).
    private func runFromXcode(kind: Kind, bundleID: String, context: ASCContext?) throws {
        #if canImport(Darwin)
        let importKind: XcodeCredentialImporter.SigningKind =
            kind == .distribution ? .distribution : .development

        let homeURL = URL(fileURLWithPath: home ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stupid-app/credentials").path)
        let store = CredentialStore(home: homeURL)
        let identityManager = IdentityManager(store: store)

        let identities = try XcodeCredentialImporter.listIdentities(kind: importKind)
        guard !identities.isEmpty else {
          throw SigningSetupError.noXcodeIdentity(kind.rawValue)
        }

        let profilesDirectory = XcodeCredentialImporter.xcodeProfilesDirectory()

        // Prefer an identity that already has an exact profile for the bundle ID, so
        // the imported profile certifies the imported certificate.
        var chosen = identities[0]
        if identities.count > 1,
           let match = identities.first(where: {
               XcodeCredentialImporter.selectProfileURL(
                   from: profilesDirectory, bundleID: bundleID, kind: importKind,
                   certSHA1: $0.sha1, teamID: $0.teamID
               ) != nil
           }) {
            chosen = match
        }

        let extracted = try XcodeCredentialImporter.extract(sha1: chosen.sha1)
        guard let teamID = chosen.teamID, !teamID.isEmpty else {
            throw SigningSetupError.teamIDMissingFromIdentity
        }
        guard let profileURL = XcodeCredentialImporter.selectProfileURL(
            from: profilesDirectory, bundleID: bundleID, kind: importKind,
            certSHA1: chosen.sha1, teamID: teamID
        ) else {
            throw SigningSetupError.noXcodeProfile(bundleID, kind.rawValue)
        }

        let certificateID = try resolveCertificateID(
            context: context, kind: kind, certPEM: extracted.certPEM
        )

        switch importKind {
        case .distribution:
            try identityManager.storeDistribution(
                privateKeyPEM: extracted.keyPEM,
                certificatePEM: extracted.certPEM,
                certificateID: certificateID,
                teamID: teamID
            )
        case .development:
            try identityManager.storeDevelopment(
                privateKeyPEM: extracted.keyPEM,
                certificatePEM: extracted.certPEM,
                certificateID: certificateID,
                teamID: teamID
            )
        }
        print("Imported \(kind.rawValue) identity from Xcode (\(chosen.commonName))")

        // Copy the original signed profile bytes so the embedded profile is unchanged.
        let profileName = kind == .distribution ? "\(bundleID) AppStore" : "\(bundleID) Development"
        let stored = try copyProfile(from: profileURL, profileName: profileName, home: homeURL)
        print("Stored provisioning profile for \(bundleID) at \(stored.path)")

        if certificateID == nil {
            print("NOTE: no App Store Connect key is stored; certificate ID was not resolved. `release upload` and new-profile creation will need `stupid-app credentials add` first.")
        }
        #else
        throw SigningSetupError.unsupported("`--from-xcode` is only available on macOS with Xcode-managed signing credentials.")
        #endif
    }

    /// Resolves an App Store Connect certificate resource ID by matching the imported
    /// certificate's content fingerprint, when an ASC context is available.
    private func resolveCertificateID(
        context: ASCContext?,
        kind: Kind,
        certPEM: String
    ) throws -> String? {
        guard let context else { return nil }
        let certificateType = kind == .distribution ? "DISTRIBUTION" : "DEVELOPMENT"
        let remoteCertificates = try context.operations().listCertificates(certificateType: certificateType)
        let localDER = try base64Data(certPEM)
        let localFingerprint = SHA256(data: localDER)
        for certificate in remoteCertificates {
            let remoteDER = try base64Data(certificate.certificateContentBase64)
            if SHA256(data: remoteDER) == localFingerprint {
                return certificate.id
            }
        }
        return nil
    }

    private func SHA256(data: Data) -> String {
        Crypto.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Copies a `.mobileprovision` file into the store's `profiles/` directory at the
    /// deterministic path used by `run` and `release archive`.
    private func copyProfile(from source: URL, profileName: String, home: URL) throws -> URL {
        let profilesDir = home.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        let url = profilesDir.appendingPathComponent("\(profileName).mobileprovision")
        try FileManager.default.copyItem(at: source, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func storeProfile(_ data: Data, profileName: String, home: URL) throws {
        let profilesDir = home.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        let url = profilesDir.appendingPathComponent("\(profileName).mobileprovision")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        print("Profile stored at \(url.path)")
    }
}

enum SigningSetupError: Error, CustomStringConvertible {
    case unsupported(String)
    case bundleIDRequired
    case storedIdentityMissingCertID
    case partialImport
    case udidRequired
    case noXcodeIdentity(String)
    case teamIDMissingFromIdentity
    case noXcodeProfile(String, String)

    var description: String {
        switch self {
        case let .unsupported(message):
            return message
        case .bundleIDRequired:
            return "Provide --bundle-id to provision."
        case .storedIdentityMissingCertID:
            return "The stored signing identity has no certificate ID; delete the stored identity and rerun."
        case .partialImport:
            return "Importing requires all of --import-key, --import-cert, and --cert-id."
        case .udidRequired:
            return "Development setup requires --udid to register the physical device."
        case let .noXcodeIdentity(kind):
            return "No '\(kind)' signing identity was found in the login Keychain. Add one in Xcode (Accounts -> Apple ID -> Manage Certificates) and rerun."
        case .teamIDMissingFromIdentity:
            return "The selected Keychain identity has no Team ID in its common name; provide one via `credentials add --team-id` and rerun."
        case let .noXcodeProfile(bundleID, kind):
            return "No '\(kind)' provisioning profile for '\(bundleID)' is installed for the selected identity. Generate one in Xcode and rerun."
        }
    }
}
