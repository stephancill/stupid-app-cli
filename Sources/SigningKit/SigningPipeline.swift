import BuildCore
import Foundation
import ProjectCore

/// The shared post-build signing and packaging pipeline used by both distribution
/// (`release archive`) and development (`run`) flows. Keeps entitlement derivation,
/// profile embedding, the one real signing pass, and IPA packaging as a single
/// independently testable boundary with explicit inputs.
public enum SigningPipeline {
    public struct Input: Sendable {
        /// Unsigned `.app` bundle produced by `Packer`.
        public var unsignedApp: URL
        public var identity: IdentityManager.SigningIdentity
        public var teamID: String
        public var profileURL: URL
        /// Source `App.entitlements` plist.
        public var sourceEntitlementsURL: URL
        public var configuration: EntitlementDeriver.Configuration
        public var bundleID: String
        public var rcodesignPath: String
        /// App product name used for the IPA filename.
        public var product: String
        public var ipaOutputDirectory: URL

        public init(
            unsignedApp: URL,
            identity: IdentityManager.SigningIdentity,
            teamID: String,
            profileURL: URL,
            sourceEntitlementsURL: URL,
            configuration: EntitlementDeriver.Configuration,
            bundleID: String,
            rcodesignPath: String,
            product: String,
            ipaOutputDirectory: URL
        ) {
            self.unsignedApp = unsignedApp
            self.identity = identity
            self.teamID = teamID
            self.profileURL = profileURL
            self.sourceEntitlementsURL = sourceEntitlementsURL
            self.configuration = configuration
            self.bundleID = bundleID
            self.rcodesignPath = rcodesignPath
            self.product = product
            self.ipaOutputDirectory = ipaOutputDirectory
        }
    }

    public struct Output {
        /// The signed `.app` bundle (signed in place).
        public var appBundle: URL
        /// The packaged `.ipa` file.
        public var ipaURL: URL
        /// Final derived entitlements, ready for inspection or verification.
        public var entitlements: [String: Any]
        /// The parsed embedded provisioning profile.
        public var profile: MobileProvisionParser.ProvisioningProfile

        public init(appBundle: URL, ipaURL: URL, entitlements: [String: Any], profile: MobileProvisionParser.ProvisioningProfile) {
            self.appBundle = appBundle
            self.ipaURL = ipaURL
            self.entitlements = entitlements
            self.profile = profile
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case identityMissingTeam
        case missingProfile(String)

        public var description: String {
            switch self {
            case .identityMissingTeam:
                return "The stored signing identity has no team ID. Re-run `stupid-app signing setup`."
            case let .missingProfile(path):
                return "No provisioning profile found at '\(path)'. Run `stupid-app signing setup` first."
            }
        }
    }

    /// Derives and reconciles entitlements, embeds the profile, signs once with the
    /// pinned `rcodesign`, and packages the IPA. Returns the signed bundle and IPA.
    public static func signAndPackage(input: Input) throws -> Output {
        guard !input.teamID.isEmpty else {
            throw Error.identityMissingTeam
        }
        guard FileManager.default.fileExists(atPath: input.profileURL.path) else {
            throw Error.missingProfile(input.profileURL.path)
        }

        let profile = try MobileProvisionParser.parse(at: input.profileURL)

        // Derive and reconcile final entitlements; write the entitlements plist to a
        // scratch location OUTSIDE the bundle so it never ships in the IPA.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-sign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let entitlementsURL = scratch.appendingPathComponent("final-entitlements.plist")
        let derived = try EntitlementDeriver.derive(
            sourceURL: input.sourceEntitlementsURL,
            configuration: input.configuration,
            bundleID: input.bundleID,
            profile: profile,
            teamID: input.teamID
        )
        try EntitlementDeriver.writeXML(derived, to: entitlementsURL)

        // Embed the profile before the single signing pass.
        let embeddedURL = input.unsignedApp.appendingPathComponent("embedded.mobileprovision")
        try FileManager.default.copyItem(at: input.profileURL, to: embeddedURL)

        // One real signing pass. Timestamps stay disabled for all iOS output.
        let signer = RcodesignSigner(rcodesignPath: input.rcodesignPath, expectedSHA256: nil)
        try signer.sign(
            appBundle: input.unsignedApp,
            identity: .init(privateKeyPEM: input.identity.privateKeyPEM, certificatePEM: input.identity.certificatePEM),
            entitlementsXMLPath: entitlementsURL,
            teamID: input.teamID
        )

        let ipaURL = try IPAPacker.pack(
            appBundle: input.unsignedApp,
            product: input.product,
            outputDirectory: input.ipaOutputDirectory
        )

        return Output(
            appBundle: input.unsignedApp,
            ipaURL: ipaURL,
            entitlements: derived,
            profile: profile
        )
    }
}
