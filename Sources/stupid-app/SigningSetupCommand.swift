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

    @Option(name: .customLong("profile-name"), help: "Profile display-name prefix (e.g. your name); the full name is '<prefix> <bundle-id> <Development|AppStore>'.")
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
        try enableRequestedCapabilities(
            operations: operations, bundleIDResourceID: bundleResourceID, bundleID: bundleID)

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
        let baseProfileName = "\(bundleID) AppStore"
        let profileName = appliedProfileName(baseProfileName)
        let existingNames = try Set(
            (try operations.listProfiles(profileType: .appStore)).map(\.name))
        var profileID: String? = try operations.findProfile(name: profileName)
        if let profileID, let content = try? operations.downloadProfile(id: profileID) {
            print("Reusing profile \(profileID) (\(profileName))")
            try storeCanonical(content, kind: .distribution, bundleID: bundleID, home: context.homeURL)
        } else {
            profileID = try operations.createAppStoreProfile(
                name: uniqueProfileName(base: profileName, taken: existingNames),
                bundleIDResourceID: bundleResourceID,
                certificateID: certificateID
            )
            let content = try operations.downloadProfile(id: profileID!)
            try storeCanonical(content, kind: .distribution, bundleID: bundleID, home: context.homeURL)
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
        try enableRequestedCapabilities(
            operations: operations, bundleIDResourceID: bundleResourceID, bundleID: bundleID)

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

        // 3. Ensure an IOS_APP_DEVELOPMENT profile for the bundle ID + certificate that
        // provisions the requested device, reconciling the profile set so stale
        // device lists never force a manual delete/recreate round-trip.
        let baseProfileName = "\(bundleID) Development"
        let profileName = appliedProfileName(baseProfileName)
        let existing = try operations.listProfiles(profileType: .development)
            .filter { $0.bundleIdentifier == bundleID }
        let existingNames = Set(existing.map(\.name))

        // Map the registered devices (UDID -> resource id) so every device we provision
        // can be referenced by id.
        let registered = try operations.listDevices()
        let deviceResourceIDByUDID = Dictionary(
            uniqueKeysWithValues: registered.compactMap { device in
                device.udid.map { ($0, device.id) }
            })
        func resourceID(for udid: String) throws -> String {
            guard let id = deviceResourceIDByUDID[udid] else {
                throw SigningSetupError.deviceNotRegistered(udid)
            }
            return id
        }

        // Reuse a candidate that already provisions this device.
        var reusableContent: Data?
        var allProvisionedUDIDs = Set<String>()
        var toDelete: [String] = []
        for summary in existing where reusableContent == nil {
            guard let content = try? operations.downloadProfile(id: summary.id) else { continue }
            let provisioned = (try? MobileProvisionParser.parse(content))?.provisionedDevices ?? []
            allProvisionedUDIDs.formUnion(provisioned)
            if provisioned.contains(deviceUDID) {
                reusableContent = content
            }
            toDelete.append(summary.id)
        }

        if let reusableContent {
            print("Reusing profile for \(bundleID) (already provisions \(deviceUDID))")
            try storeCanonical(reusableContent, kind: .development, bundleID: bundleID, home: context.homeURL)
        } else {
            // Create a replacement provisioning the union of all previously provisioned
            // devices plus the newly requested one, validate it locally, then retire the
            // stale remote profiles only after the replacement is stored.
            allProvisionedUDIDs.insert(deviceUDID)
            let deviceIDs = try allProvisionedUDIDs.map(resourceID(for:))
            let newName = uniqueProfileName(base: profileName, taken: existingNames)
            let created = try operations.createDevelopmentProfileUnion(
                name: newName,
                bundleIDResourceID: bundleResourceID,
                certificateID: certificateID,
                deviceIDs: deviceIDs)
            let parsed = try MobileProvisionParser.parse(created.content)
            guard parsed.provisionedDevices.contains(deviceUDID) else {
                throw SigningSetupError.profileProvisionsWrongDevices(bundleID, deviceUDID)
            }
            try storeCanonical(created.content, kind: .development, bundleID: bundleID, home: context.homeURL)
            for staleID in toDelete {
                try? operations.deleteProfile(id: staleID)
            }
            print("Created replacement profile \(newName) provisioning \(deviceIDs.count) device(s); retired \(toDelete.count) stale profile(s).")
        }
        print("Development signing setup complete.")
    }

    /// Enables the capabilities a project requests on a bundle ID, derived from the
    /// entitlements of the app and every configured extension. Best-effort: a failed
    /// enable is reported but the authoritative gate is the profile-authorization check
    /// at signing time (concrete resource associations, e.g. an App Group identity,
    /// remain manual Developer Portal steps).
    private func enableRequestedCapabilities(
        operations: ASCOperations, bundleIDResourceID: String, bundleID: String
    ) throws {
        for capability in projectRequestedCapabilities() {
            do {
                try operations.enableBundleIDCapability(
                    bundleIDResourceID: bundleIDResourceID, capabilityType: capability.type)
                print("Enabled \(capability.displayName) capability on \(bundleID)")
            } catch {
                print(
                    "WARNING: could not enable \(capability.displayName) capability on \(bundleID): \(error). The concrete association remains a manual Developer Portal step.")
            }
        }
    }

    /// The capabilities the project requests, derived from the source entitlements of
    /// the app and every configured extension. An entitlement set requests a capability
    /// when any bundle declares the corresponding source entitlement key.
    private func projectRequestedCapabilities() -> [SigningCapability] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "stupid-app.yml")),
            let config = try? AppConfig.decode(data)
        else { return [] }
        var entitlementsPaths = [config.entitlementsPath].compactMap { $0 }
        if let extensions = config.extensions {
            entitlementsPaths += extensions.compactMap { $0.entitlementsPath }
        }
        var requested: [SigningCapability] = []
        for path in entitlementsPaths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any]
            else { continue }
            for capability in SigningCapability.all where plist[capability.entitlementKey] != nil {
                if !requested.contains(capability) {
                    requested.append(capability)
                }
            }
        }
        return requested
    }

    /// A mapping from a source entitlement key to the App Store Connect capability that
    /// must be enabled on a bundle ID so the downloaded profile authorizes it.
    private struct SigningCapability: Equatable {
        let entitlementKey: String
        let type: String
        let displayName: String

        static let appGroups = SigningCapability(
            entitlementKey: "com.apple.security.application-groups",
            type: "APP_GROUPS",
            displayName: "App Groups"
        )
        static let autoFillCredentialProvider = SigningCapability(
            entitlementKey: "com.apple.developer.authentication-services" +
                ".autofill-credential-provider",
            type: "AUTOFILL_CREDENTIAL_PROVIDER",
            displayName: "AutoFill Credential Provider"
        )

        static let all: [SigningCapability] = [.appGroups, .autoFillCredentialProvider]
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

    /// Returns the explicitly-supplied bundle IDs, or the bundle IDs from a
    /// `stupid-app.yml` present in the current directory (the app plus every
    /// configured extension) when none were supplied.
    private func resolveBundleIDs() throws -> [String] {
        if !bundleIDs.isEmpty { return bundleIDs }
        let configURL = URL(fileURLWithPath: "stupid-app.yml")
        guard let data = try? Data(contentsOf: configURL) else { return [] }
        let config = try AppConfig.decode(data)
        var ids = [config.bundleID]
        if let extensions = config.extensions {
            ids += extensions.map(\.bundleID)
        }
        return ids
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
        let profileKind: ProfileKind = kind == .distribution ? .distribution : .development
        let stored = try copyToCanonicalProfile(
            from: profileURL, kind: profileKind, bundleID: bundleID, home: homeURL)
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

    /// Copies a `.mobileprovision` file into the store at the content-addressed canonical
    /// path used by `run` and `release archive`.
    private func copyToCanonicalProfile(from source: URL, kind: ProfileKind, bundleID: String, home: URL) throws -> URL {
        guard let data = try? Data(contentsOf: source) else {
            throw SigningSetupError.profileCopyFailed(source.path)
        }
        return try storeCanonical(data, kind: kind, bundleID: bundleID, home: home)
    }

    /// Stores a downloaded profile at its canonical `<kind>/<bundleID>` path and prints
    /// the location.
    @discardableResult
    private func storeCanonical(_ data: Data, kind: ProfileKind, bundleID: String, home: URL) throws -> URL {
        let url = try ProfileStore.store(data, home: home, kind: kind, bundleID: bundleID)
        print("Profile stored at \(url.path)")
        return url
    }

    /// Applies the user-provided `--profile-name` as a prefix to the derived base name,
    /// so app and extension profiles never collide on a shared display name.
    private func appliedProfileName(_ base: String) -> String {
        profileName.map { "\($0) \(base)" } ?? base
    }

    /// Returns `base`, or `base <n>` for the first `n >= 2` not present in `taken`, so a
    /// replacement profile never collides with an existing one on App Store Connect.
    private func uniqueProfileName(base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
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
    case deviceNotRegistered(String)
    case profileProvisionsWrongDevices(String, String)
    case profileCopyFailed(String)

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
        case let .deviceNotRegistered(udid):
            return "The device '\(udid)' is not registered with App Store Connect. Run `stupid-app devices add --udid \(udid)` first."
        case let .profileProvisionsWrongDevices(bundleID, udid):
            return "The newly created profile for '\(bundleID)' does not provision the requested device '\(udid)'. Check the developer portal profile and rerun."
        case let .profileCopyFailed(path):
            return "Could not copy the provisioning profile from '\(path)'."
        }
    }
}
