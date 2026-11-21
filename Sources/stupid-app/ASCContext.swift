import Foundation
import ASCKit

/// Resolves App Store Connect access and the credential-store location shared by
/// commands that talk to the App Store Connect API or sign artifacts.
///
/// With `STUPID_APP_RELEASE_SESSION` set, App Store Connect goes through that release
/// session and the team comes from it; no App Store Connect key is read. Otherwise the
/// stored key and team ID are used.
struct ASCContext {
    enum Access {
        case apiKey(ASCKey)
        case releaseSession(ReleaseSession, ReleaseSession.Info)
    }

    let access: Access
    let teamID: String
    let homeURL: URL
    let credentialStore: CredentialStore

    /// Resolves access. `purpose` names the operation in an error.
    static func resolve(home: String?, purpose: String) throws -> ASCContext {
        let homePath = home ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stupid-app/credentials").path
        let homeURL = URL(fileURLWithPath: homePath)
        let store = CredentialStore(home: homeURL)
        if let session = try ReleaseSession.fromEnvironment() {
            let info = try session.info()
            return ASCContext(
                access: .releaseSession(session, info), teamID: info.teamId, homeURL: homeURL,
                credentialStore: store)
        }
        let storedTeamID = try store.loadTeamID()
        let storedKey = try store.loadASCKey()
        guard let storedTeamID else {
            throw CredentialStore.Error.unreadableSecret("developer-team-id")
        }
        return ASCContext(access: .apiKey(storedKey), teamID: storedTeamID, homeURL: homeURL, credentialStore: store)
    }

    /// The release session, when App Store Connect and signing go through one.
    var releaseSession: (session: ReleaseSession, info: ReleaseSession.Info)? {
        if case let .releaseSession(session, info) = access { return (session, info) }
        return nil
    }

    func client() -> ASCClient {
        switch access {
        case let .apiKey(key):
            return ASCClient(jwt: {
                try ASCJWTGenerator(key: key).generate()
            })
        case let .releaseSession(session, _):
            return session.ascClient()
        }
    }

    func operations() -> ASCOperations {
        ASCOperations(client: client())
    }
}
