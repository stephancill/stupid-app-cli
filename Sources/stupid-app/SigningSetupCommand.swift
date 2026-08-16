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

/// `stupid-app signing setup`: creates distribution or development identities and
/// provisioning profiles through the App Store Connect public API.
struct SigningSetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Create or import an Apple signing identity and provisioning profile."
    )

    enum Kind: String, CaseIterable, ExpressibleByArgument {
        case distribution
        case development
    }

    @Option(name: .customLong("kind"), help: "signing kind: distribution or development.")
    var kind: Kind = .distribution

    @Option(name: .customLong("bundle-id"), help: "Exact bundle identifier to provision.")
    var bundleID: String?

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

    @Option(name: .customLong("home"), help: "Credential store directory.")
    var home: String?

    mutating func run() async throws {
        let context = try ASCContext.resolve(home: home, purpose: "signing setup")
        let operations = context.operations()
        let identityManager = IdentityManager(store: context.credentialStore)

        guard let bundleID else {
            throw SigningSetupError.bundleIDRequired
        }

        let importRequested = [importKeyPath, importCertPath, importCertID].filter { $0 != nil }.count
        if importRequested > 0, importRequested != 3 {
            throw SigningSetupError.partialImport
        }

        switch kind {
        case .distribution:
            try runDistribution(
                operations: operations,
                identityManager: identityManager,
                context: context,
                bundleID: bundleID
            )
        case .development:
            try runDevelopment(
                operations: operations,
                identityManager: identityManager,
                context: context,
                bundleID: bundleID
            )
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
        bundleID: String
    ) throws {
        // 1. Bundle ID and physical device.
        let bundleResourceID = try operations.getOrCreateBundleID(name: bundleID, identifier: bundleID)
        print("Bundle ID \(bundleID) -> \(bundleResourceID)")

        guard let deviceUDID else {
            throw SigningSetupError.udidRequired
        }
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
        }
    }
}
