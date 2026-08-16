import ArgumentParser
import Foundation
import ASCKit
import SigningKit

/// `stupid-app credentials`: manage App Store Connect and developer team credentials
/// in the credential store.
struct CredentialsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "credentials",
        abstract: "Manage App Store Connect credentials and team identity.",
        subcommands: [CredentialsAddCommand.self]
    )
}

/// `stupid-app credentials add`: stores the App Store Connect API key and developer
/// team ID in the credential store.
struct CredentialsAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Store App Store Connect API key and developer team identity."
    )

    @Option(name: .customLong("key-id"), help: "App Store Connect API key ID.")
    var keyID: String?

    @Option(name: .customLong("issuer-id"), help: "App Store Connect issuer ID.")
    var issuerID: String?

    @Option(name: .customLong("p8"), help: "Path to the App Store Connect .p8 API key file.")
    var p8Path: String?

    @Option(name: .customLong("team-id"), help: "Apple Developer Team ID.")
    var teamID: String?

    @Option(name: .customLong("home"), help: "Credential store directory (default ~/.stupid-app/credentials).")
    var home: String?

    mutating func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let homeURL = URL(fileURLWithPath: home ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stupid-app/credentials").path)
        let store = CredentialStore(home: homeURL)

        let keyID = self.keyID ?? env["ASC_API_KEY_ID"]
        let issuerID = self.issuerID ?? env["ASC_API_ISSUER_ID"]
        let p8Path = self.p8Path ?? env["ASC_API_KEY_PATH"]
        let teamID = self.teamID ?? env["DEVELOPER_TEAM_ID"]

        guard let keyID, let issuerID, let p8Path else {
            throw CredentialCommandError.missingInputs
        }
        guard let teamID else {
            throw CredentialCommandError.missingTeamID
        }

        guard let pem = try? String(contentsOf: URL(fileURLWithPath: p8Path), encoding: .utf8) else {
            throw CredentialCommandError.p8Unreadable(p8Path)
        }
        // Validate the key actually parses before storing anything.
        _ = try ASCJWTGenerator.parsedKey(fromPEM: pem)

        let apiKey = ASCKey(keyID: keyID, issuerID: issuerID, pem: pem)
        try store.writeSecret("asc.key.pem", data: Data(apiKey.pem.utf8))
        try store.writeSecret("asc.key-id", data: Data(apiKey.keyID.utf8))
        try store.writeSecret("asc.issuer-id", data: Data(apiKey.issuerID.utf8))
        try store.writeSecret("developer-team-id", data: Data(teamID.utf8))

        print("Stored ASC credentials and team ID in \(homeURL.path)")
    }
}

enum CredentialCommandError: Error, CustomStringConvertible {
    case missingInputs
    case missingTeamID
    case p8Unreadable(String)

    var description: String {
        switch self {
        case .missingInputs:
            return "Provide --key-id, --issuer-id, and --p8 (or set ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_PATH)."
        case .missingTeamID:
            return "Provide --team-id (or set DEVELOPER_TEAM_ID)."
        case let .p8Unreadable(path):
            return "Could not read the App Store Connect key at '\(path)'."
        }
    }
}