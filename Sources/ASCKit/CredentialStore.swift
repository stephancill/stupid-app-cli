import Foundation

/// Permission-hardened credential storage.
///
/// Layout: one directory (mode `0700`) containing per-secret files (mode `0600`).
/// Secrets are stored as plaintext files readable and writable only by the owning
/// user (root/sudo still has access by default). All writes are atomic
/// (write-then-rename). Calling code never persists secrets in command output,
/// logs, or manifests.
public struct CredentialStore {
    public var home: URL

    public init(home: URL) {
        self.home = home
    }

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case unreadableSecret(String)

        public var description: String {
            switch self {
            case let .unreadableSecret(name):
                return "Could not read credential '\(name)'. Re-run `stupid-app credentials add` first."
            }
        }
    }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try setPermissions(home, mode: 0o700)
    }

    /// Atomically writes a secret as a plaintext file with mode `0600`.
    public func writeSecret(_ name: String, data: Data) throws {
        try ensureDirectory()
        let url = fileURL(forSecret: name)
        let temporary = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        try setPermissions(temporary, mode: 0o600)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    /// Reads a secret file. A missing file fails loudly.
    public func readSecret(_ name: String) throws -> Data {
        let url = fileURL(forSecret: name)
        guard let data = try? Data(contentsOf: url) else {
            throw Error.unreadableSecret(name)
        }
        return data
    }

    /// A stable file URL for a secret name. The name is validated to be a single
    /// path component so it can never escape `home`.
    public func fileURL(forSecret name: String) -> URL {
        precondition(!name.contains("/") && !name.contains(".."), "invalid secret name")
        return home.appendingPathComponent(name)
    }

    /// Names used by `stupid-app credentials add`.
    public enum Secret: String {
        case ascKey = "asc.key.pem"
        case ascKeyID = "asc.key-id"
        case ascIssuerID = "asc.issuer-id"
        case developerTeamID = "developer-team-id"
    }

    /// Loads the stored App Store Connect key.
    public func loadASCKey() throws -> ASCKey {
        guard exists(Secret.ascKey.rawValue),
              exists(Secret.ascKeyID.rawValue),
              exists(Secret.ascIssuerID.rawValue) else {
            throw Error.unreadableSecret("stored ASC key (run `stupid-app credentials add` first)")
        }
        let pem = String(decoding: try readSecret(Secret.ascKey.rawValue), as: UTF8.self)
        let keyID = String(decoding: try readSecret(Secret.ascKeyID.rawValue), as: UTF8.self)
        let issuer = String(decoding: try readSecret(Secret.ascIssuerID.rawValue), as: UTF8.self)
        return ASCKey(keyID: keyID, issuerID: issuer, pem: pem)
    }

    /// Loads the stored developer team ID.
    public func loadTeamID() throws -> String? {
        guard exists(Secret.developerTeamID.rawValue) else { return nil }
        return String(decoding: try readSecret(Secret.developerTeamID.rawValue), as: UTF8.self)
    }

    public func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(forSecret: name).path)
    }

    private func setPermissions(_ url: URL, mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}