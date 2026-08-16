import Crypto
import Foundation

/// App Store Connect API key material. The `pem` is the `.p8` EC P-256 private key.
public struct ASCKey: Sendable, Equatable {
    public var keyID: String
    public var issuerID: String
    public var pem: String

    public init(keyID: String, issuerID: String, pem: String) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.pem = pem
    }
}

/// Generates ES256 signed JWTs for App Store Connect. Reuses the last token until it
/// is close to expiry to avoid pointless signing work; the raw 64-byte `r || s`
/// signature representation is used, as required by App Store Connect.
public struct ASCJWTGenerator {
    /// App Store Connect allows a maximum 20-minute lifetime. 15 minutes accounts for
    /// reasonable clock drift.
    public static let ttl: TimeInterval = 60 * 15
    /// Reuse the last token while it has at least this much time remaining.
    public static let tolerance: TimeInterval = 60 * 2

    private let key: ASCKey
    private let now: @Sendable () -> Date
    private let parsedKey: P256.Signing.PrivateKey

    public init(key: ASCKey, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.key = key
        self.now = now
        self.parsedKey = try Self.parsedKey(fromPEM: key.pem)
    }

    /// Parses the `.p8` PEM into a P-256 signing private key.
    public static func parsedKey(fromPEM pem: String) throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(pemRepresentation: pem)
    }

    /// Produces a signed JWT valid from `now` for `Self.ttl` seconds.
    public func generate() throws -> String {
        let issuedAt = now()
        let expiry = issuedAt + Self.ttl

        let header = ["alg": "ES256", "kid": key.keyID, "typ": "JWT"]
        let payload: [String: Sendable] = [
            "iss": key.issuerID,
            "iat": Int(issuedAt.timeIntervalSince1970),
            "exp": Int(expiry.timeIntervalSince1970),
            "aud": "appstoreconnect-v1",
        ]

        let headerEncoded = Self.base64URL(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let payloadEncoded = Self.base64URL(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let body = "\(headerEncoded).\(payloadEncoded)"

        let signature = try parsedKey.signature(for: Data(body.utf8)).rawRepresentation
        return "\(body).\(Self.base64URL(signature))"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum ASCJWTError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidPEMKey(String)

    public var description: String {
        switch self {
        case let .invalidPEMKey(detail):
            return "Could not parse the App Store Connect API key. \(detail)"
        }
    }
}