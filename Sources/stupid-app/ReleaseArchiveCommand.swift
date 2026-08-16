import ArgumentParser
import Foundation
import ASCKit
import BuildCore
import ProjectCore
import SDKCore
import SigningKit

/// `stupid-app release`: distribution build, signing, and upload operations.
struct ReleaseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Distribution build, signing, and upload operations.",
        subcommands: [ReleaseArchiveCommand.self, ReleaseUploadCommand.self]
    )
}

/// `stupid-app release archive`: builds the app unsigned, derives and reconciles
/// distribution entitlements, embeds the App Store profile, signs once with the pinned
/// `rcodesign` (timestamps disabled), packages the IPA, and verifies it.
struct ReleaseArchiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive",
        abstract: "Build, sign, and package a distribution IPA."
    )

    @Option(name: .customLong("sdk-id"), help: "Imported Swift SDK identifier (default stupid-app-ios).")
    var sdkID: String = "stupid-app-ios"

    @Option(name: .customLong("swift"), help: "Path to the host `swift` executable.")
    var swiftPath: String = "swift"

    @Option(name: .customLong("rcodesign"), help: "Path to the pinned rcodesign binary.")
    var rcodesignPath: String = "rcodesign"

    @Option(name: .customLong("sdk-version"), help: "Override the SDK version reported in LC_BUILD_VERSION.")
    var sdkVersionOverride: String?

    @Option(name: .customLong("home"), help: "Credential store directory.")
    var home: String?

    @Option(name: .customLong("output"), help: "Directory for the IPA (defaults to ./.release).")
    var output: String?

    mutating func run() async throws {
        let context = try ASCContext.resolve(home: home, purpose: "release archive")

        let configURL = URL(fileURLWithPath: "stupid-app.yml")
        guard let data = try? Data(contentsOf: configURL) else {
            throw ProjectError.unreadableConfig(configURL.path)
        }
        let config = try AppConfig.decode(data)
        let projectRoot = URL(fileURLWithPath: ".")

        // 1. Build the unsigned app (release configuration).
        let planner = Planner(projectRoot: projectRoot, config: config, swiftPath: swiftPath)
        let plan = try planner.makePlan()
        let resolvedSDKID = sdkID
        let resolvedSwift = swiftPath
        let resolvedOverride = sdkVersionOverride
        guard SDKVersion.isInstalled(sdkID: resolvedSDKID, swiftPath: resolvedSwift) else {
            throw SDKVersion.Error.sdkNotInstalled(resolvedSDKID)
        }
        let packer = Packer(
            projectRoot: projectRoot,
            plan: plan,
            config: config,
            swiftPath: swiftPath,
            sdkID: sdkID,
            sdkVersion: { @Sendable in
                try SDKVersion.resolve(sdkID: resolvedSDKID, targetTriple: "arm64-apple-ios", swiftPath: resolvedSwift, override: resolvedOverride)
            },
            buildConfiguration: .release
        )
        let unsignedApp = try packer.pack()
        print("Assembled unsigned \(unsignedApp.path)")

        // 2. Load the distribution identity and App Store profile.
        let identity = try IdentityManager(store: context.credentialStore).loadDistribution()
        guard let teamID = identity.teamID else {
            throw ReleaseArchiveError.identityMissingTeam
        }
        let profileURL = try locateProfile(home: context.homeURL, bundleID: config.bundleID)

        // 3. Sign once (distribution) and package the IPA.
        let outputDir = URL(fileURLWithPath: output ?? projectRoot.appendingPathComponent(".release").path)
        let output = try SigningPipeline.signAndPackage(input: .init(
            unsignedApp: unsignedApp,
            identity: identity,
            teamID: teamID,
            profileURL: profileURL,
            sourceEntitlementsURL: projectRoot.appendingPathComponent(config.entitlementsPath ?? "App.entitlements"),
            configuration: .distribution,
            bundleID: config.bundleID,
            rcodesignPath: rcodesignPath,
            product: config.product,
            ipaOutputDirectory: outputDir
        ))
        print("Signed \(output.appBundle.path)")
        print("Packaged \(output.ipaURL.path)")
        print("IPA SHA-256: \(try SHA256.file(at: output.ipaURL))")

        // 4. Independent signature check.
        let signer = RcodesignSigner(rcodesignPath: rcodesignPath, expectedSHA256: nil)
        let sigInfo = try signer.printSignatureInfo(at: output.appBundle.path)
        print("Signature info:\n\(sigInfo)")
    }

    private func locateProfile(home: URL, bundleID: String) throws -> URL {
        let candidates = [
            home.appendingPathComponent("profiles/\(bundleID) AppStore.mobileprovision"),
            home.appendingPathComponent("profiles/\(bundleID).mobileprovision"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        throw ReleaseArchiveError.profileMissing(bundleID)
    }
}

enum ReleaseArchiveError: Error, CustomStringConvertible {
    case profileMissing(String)
    case identityMissingTeam

    var description: String {
        switch self {
        case let .profileMissing(bundleID):
            return "No App Store profile found for '\(bundleID)'. Run `stupid-app signing setup --kind distribution` first."
        case .identityMissingTeam:
            return "The stored distribution identity has no team ID. Re-run `stupid-app signing setup --kind distribution`."
        }
    }
}
