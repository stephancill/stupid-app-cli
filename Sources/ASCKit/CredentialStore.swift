import Crypto
import Foundation

/// Encrypted, permission-hardened credential storage.
///
/// Layout: one directory (mode `0700`) containing per-secret files (mode `0600`).
/// Secret files are encrypted at rest with AES-256-GCM using a key derived from a
/// passphrase via HKDF-SHA256 with a random per-file salt; the salt, nonce,
/// ciphertext, and tag are stored in one combined blob. All writes are atomic
/// (write-then-rename). Calling code never persists plaintext secrets.
public struct CredentialStore {
    public var home: URL
    public var passphrase: () -> String?

    public init(home: URL, passphrase: @escaping () -> String?) {
        self.home = home
        self.passphrase = passphrase
    }

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case passphraseUnavailable(String)
        case decryptionFailed(String)
        case secretNotEncrypted(String)

        public var description: String {
            switch self {
            case let .passphraseUnavailable(name):
                return "A credential passphrase is required to \(name). Set STUPID_APP_CREDENTIAL_PASSWORD or pass --credential-password."
            case let .decryptionFailed(name):
                return "Could not decrypt '\(name)'. The credential passphrase may be wrong."
            case let .secretNotEncrypted(name):
                return "Refusing to read '\(name)': it is not an encrypted secret blob."
            }
        }
    }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try setPermissions(home, mode: 0o700)
    }

    /// Derives a per-secret AES-256 key from the passphrase and a random salt.
    private func key(passphrase: String, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)),
            salt: salt,
            info: Data("stupid-app.credentials.v1".utf8),
            outputByteCount: 32
        )
    }

    /// Encrypts and atomically writes a secret. A missing passphrase fails loudly.
    public func writeSecret(_ name: String, data: Data) throws {
        try ensureDirectory()
        guard let passphrase = passphrase() else {
            throw Error.passphraseUnavailable("write '\(name)'")
        }
        let salt = try generateBytes(16)
        let key = self.key(passphrase: passphrase, salt: salt)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combinedData = sealed.combined else {
            throw Error.decryptionFailed(name)
        }
        var combined = salt
        combined.append(combinedData)
        try atomicWrite(combined, to: fileURL(forSecret: name), mode: 0o600)
    }

    /// Reads and decrypts a secret. A missing passphrase fails loudly; a non-secret
    /// (unencrypted) file is rejected rather than silently treated as plaintext.
    public func readSecret(_ name: String) throws -> Data {
        guard let passphrase = passphrase() else {
            throw Error.passphraseUnavailable("read '\(name)'")
        }
        let url = fileURL(forSecret: name)
        guard let combined = try? Data(contentsOf: url), combined.count > 16 else {
            throw Error.secretNotEncrypted(name)
        }
        let salt = combined.prefix(16)
        let sealedData = combined.dropFirst(16)
        let key = self.key(passphrase: passphrase, salt: Data(salt))
        guard let sealed = try? AES.GCM.SealedBox(combined: sealedData),
              let opened = try? AES.GCM.open(sealed, using: key) else {
            throw Error.decryptionFailed(name)
        }
        return opened
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
            throw Error.secretNotEncrypted("stored ASC key (run `stupid-app credentials add` first)")
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

    private func atomicWrite(_ data: Data, to url: URL, mode: Int) throws {
        let temporary = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        try setPermissions(temporary, mode: mode)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
    }

    private func setPermissions(_ url: URL, mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func generateBytes(_ count: Int) throws -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return Data(bytes)
    }
}