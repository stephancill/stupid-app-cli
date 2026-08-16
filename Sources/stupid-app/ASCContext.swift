import Foundation
import ASCKit

/// Resolves App Store Connect credentials from the plaintext credential store and
/// the credential-store location shared by commands that talk to the App Store
/// Connect API or sign artifacts.
struct ASCContext {
    let apiKey: ASCKey
    let teamID: String
    let homeURL: URL
    let credentialStore: CredentialStore

    /// Resolves credentials. `purpose` names the operation in an error.
    static func resolve(home: String?, purpose: String) throws -> ASCContext {
        let homePath = home ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stupid-app/credentials").path
        let homeURL = URL(fileURLWithPath: homePath)
        let store = CredentialStore(home: homeURL)
        let storedTeamID = try store.loadTeamID()
        let storedKey = try store.loadASCKey()
        guard let storedTeamID else {
            throw CredentialStore.Error.unreadableSecret("developer-team-id")
        }
        return ASCContext(apiKey: storedKey, teamID: storedTeamID, homeURL: homeURL, credentialStore: store)
    }

    func client() -> ASCClient {
        let key = apiKey
        return ASCClient(jwt: {
            try ASCJWTGenerator(key: key).generate()
        })
    }

    func operations() -> ASCOperations {
        ASCOperations(client: client())
    }
}