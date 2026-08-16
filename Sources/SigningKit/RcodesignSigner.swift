import BuildCore
import Foundation
import SDKCore

/// Wraps the pinned `rcodesign` binary as the low-level signing kernel. It handles
/// Mach-O signing, nested-bundle resource sealing, CMS, and entitlements; iOS policy
/// (profile embedding, entitlement authorization, IPA layout, timestamp disabling)
/// lives in this project.
public struct RcodesignSigner {
    public var rcodesignPath: String
    /// Optional SHA-256 expected for the `rcodesign` binary; when set, the signer
    /// refuses to run an unexpected binary.
    public var expectedSHA256: String?

    public init(rcodesignPath: String, expectedSHA256: String? = nil) {
        self.rcodesignPath = rcodesignPath
        self.expectedSHA256 = expectedSHA256
    }

    public struct IdentityInput {
        public var privateKeyPEM: String
        public var certificatePEM: String

        public init(privateKeyPEM: String, certificatePEM: String) {
            self.privateKeyPEM = privateKeyPEM
            self.certificatePEM = certificatePEM
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case binaryMissing(String)
        case checksumMismatch(String, String)
        case signingFailed(String)

        public var description: String {
            switch self {
            case let .binaryMissing(path):
                return "The pinned rcodesign binary is missing at '\(path)'. Reinstall it via the signer setup step."
            case let .checksumMismatch(path, actual):
                return "rcodesign at '\(path)' has unexpected SHA-256 \(actual). Refusing to sign; reinstall the pinned binary."
            case let .signingFailed(stderr):
                return "rcodesign failed.\n\(stderr)"
            }
        }
    }

    /// Verifies the pinned binary exists and, when configured, matches its checksum.
    public func validateBinary() throws {
        guard FileManager.default.isExecutableFile(atPath: rcodesignPath) else {
            throw Error.binaryMissing(rcodesignPath)
        }
        if let expectedSHA256 {
            let actual = try SHA256.file(at: URL(fileURLWithPath: rcodesignPath))
            guard actual == expectedSHA256 else {
                throw Error.checksumMismatch(rcodesignPath, actual)
            }
        }
    }

    /// Signs an `.app` bundle once. Distribution signing disables timestamps.
    /// - Parameters:
    ///   - appBundle: the bundle to sign in place.
    ///   - identity: PEM key + certificate to sign with.
    ///   - entitlementsXMLPath: final entitlement plist path.
    ///   - teamID: Apple Developer team ID recorded in the signature.
    public func sign(
        appBundle: URL,
        identity: IdentityInput,
        entitlementsXMLPath: URL,
        teamID: String
    ) throws {
        try validateBinary()

        // Write identity material to a private temp dir (mode 0600) for the signer.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-sign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pemURL = tempDir.appendingPathComponent("identity.pem")
        let pemData = (identity.privateKeyPEM + "\n" + identity.certificatePEM + "\n")
        try pemData.data(using: .utf8)?.write(to: pemURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pemURL.path)

        // Use in-place signing (same input and output path).
        let result = try ProcessRunner.run(
            executable: rcodesignPath,
            arguments: [
                "sign",
                "--pem-file", pemURL.path,
                "--timestamp-url", "none",
                "--entitlements-xml-file", entitlementsXMLPath.path,
                "--team-name", teamID,
                "--verbose",
                appBundle.path,
            ]
        )
        guard result.succeeded else {
            throw Error.signingFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    /// Prints signature information for an artifact; used for independent verification.
    public func printSignatureInfo(at path: String) throws -> String {
        try validateBinary()
        let result = try ProcessRunner.run(
            executable: rcodesignPath,
            arguments: ["print-signature-info", path]
        )
        guard result.succeeded else {
            throw Error.signingFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return result.stdout
    }

    /// Returns the first line of `rcodesign --version` for provenance reporting, or nil
    /// when the binary is unavailable.
    public static func version(rcodesignPath: String) throws -> String? {
        let resolved = HostInfo.resolveExecutable(rcodesignPath)
        guard FileManager.default.isExecutableFile(atPath: resolved) else { return nil }
        let result = try ProcessRunner.run(executable: resolved, arguments: ["--version"])
        guard result.succeeded else { return nil }
        return result.stdout.split(separator: "\n").first.map(String.init)
    }
}