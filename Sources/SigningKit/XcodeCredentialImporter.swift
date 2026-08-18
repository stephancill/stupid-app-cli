import BuildCore
import Foundation

#if canImport(Darwin)
import Crypto
import Security

/// macOS-only importer that reuses the signing credentials Xcode already manages.
///
/// Xcode stores signing identities (private key + certificate) as codesigning
/// identities in the login Keychain and downloaded provisioning profiles under
/// `~/Library/MobileDevice/Provisioning Profiles`. This importer enumerates those
/// identities, extracts the selected one to PEM, and selects an exact provisioning
/// profile for a bundle ID and signing kind.
///
/// The Keychain and Xcode's profile folder are used only as a one-time bootstrap
/// source; material is stored in the permission-hardened credential store and signing
/// continues to use the project-owned native signer. This is a deliberate, documented
/// extension of the macOS host-support non-goal, which only excludes Keychain usage as
/// a signing kernel.
public enum XcodeCredentialImporter {
  public enum SigningKind: String {
    case development = "Apple Development:"
    case distribution = "Apple Distribution:"
  }

  /// A valid codesigning identity enumerated from the login Keychain.
  public struct Candidate: Sendable {
    public var sha1: String
    public var commonName: String
    public var teamID: String?
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case unsupported(String)
    case openSSLUnavailable
    case identityNotFound
    case keyNotFound
    case profileNotFound(String)

    public var description: String {
      switch self {
      case .unsupported(let message):
        return message
      case .openSSLUnavailable:
        return "OpenSSL 3 was not found, so a signing identity could not be exported from the Keychain. Install it (e.g. `brew install openssl@3`) and rerun."
      case .identityNotFound:
        return "No matching signing identity was found in the login Keychain."
      case .keyNotFound:
        return "The matching private key could not be extracted from any accessible Keychain. The identity's private key may live in a password-protected or locked Keychain; import it into the login Keychain (or supply --import-key/--import-cert) and rerun."
      case .profileNotFound(let bundleID):
        return "No \(bundleID) provisioning profile was found in ~/Library/MobileDevice/Provisioning Profiles for the selected identity."
      }
    }
  }

  /// The directory where Xcode stores downloaded provisioning profiles.
  public static func xcodeProfilesDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/MobileDevice/Provisioning Profiles", isDirectory: true)
  }

  /// Enumerates valid codesigning identities for a kind from the default keychain
  /// search list (the same identities `security find-identity -p codesigning` reports).
  public static func listIdentities(kind: SigningKind) throws -> [Candidate] {
    let result = try ProcessRunner.run(
      executable: "/usr/bin/security",
      arguments: ["find-identity", "-v", "-p", "codesigning"],
      configuration: ProcessRunner.Configuration(maxOutputBytes: 200_000)
    )
    guard result.succeeded else {
      throw Error.unsupported(
        "Could not enumerate Keychain signing identities: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }
    var candidates: [Candidate] = []
    for line in result.stdout.split(separator: "\n") {
      guard let (hash, cn) = parseIdentityLine(String(line)) else { continue }
      guard cn.hasPrefix(kind.rawValue) else { continue }
      candidates.append(Candidate(sha1: hash, commonName: cn, teamID: teamID(fromCN: cn)))
    }
    return candidates
  }

  /// Extracts the certificate (PEM) and private key (PEM) for an identity selected by
  /// its certificate SHA-1 (as reported by `security find-identity`).
  ///
  /// The login Keychain does not allow the raw private key to be retrieved through
  /// `SecKeyCopyExternalRepresentation`, so the identity is exported as a PKCS#12 file
  /// and split with OpenSSL. The correct key is matched to the chosen certificate by
  /// comparing RSA moduli, so bag ordering is irrelevant. Temporary files live in a
  /// mode-0700 directory and are removed on both success and failure.
  public static func extract(sha1: String) throws -> (certPEM: String, keyPEM: String) {
    let openssl = try resolveOpenSSL()

    // 1. Locate the certificate whose DER SHA-1 matches the identity hash.
    let certs = try ProcessRunner.run(
      executable: "/usr/bin/security",
      arguments: ["find-certificate", "-a", "-p"],
      configuration: ProcessRunner.Configuration(maxOutputBytes: 4_000_000)
    )
    guard certs.succeeded else {
      throw Error.unsupported("Could not read Keychain certificates: \(certs.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    let certPEM = try matchCertificatePEM(bySHA1: sha1, in: certs.stdout)

    // 2. Export identities from every accessible keychain in the search list.
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpDir.path)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let passphrase = UUID().uuidString
    let exported = try exportIdentityKeychains(openssl: openssl, passphrase: passphrase, tmpDir: tmpDir)
    guard !exported.isEmpty else {
      throw Error.unsupported(
        "Could not export signing identities from any accessible Keychain. Unlock the Keychain that holds the signing private key (or grant this terminal access to it) and rerun."
      )
    }

    // 3. Match the private key whose RSA modulus equals the certificate's modulus.
    let keyPEM = try matchPrivateKey(
      certPEM: certPEM,
      candidates: Data(exported.joined(separator: "\n").utf8),
      openssl: openssl,
      tmpDir: tmpDir
    )
    return (certPEM, keyPEM)
  }

  /// Exports identities from the user/domain keychain search list as split PEM. Returns
  /// the combined private-key/certificate PEM blocks from every keychain that exported
  /// successfully. Locked or password-protected keychains are skipped (a password one
  /// does not know must not block an otherwise available identity).
  static func exportIdentityKeychains(openssl: String, passphrase: String, tmpDir: URL) throws -> [String] {
    var keychains: [URL] = []
    for arguments in [["list-keychains", "-d", "user"], ["list-keychains"]] {
      if let result = try? ProcessRunner.run(
        executable: "/usr/bin/security",
        arguments: arguments,
        configuration: ProcessRunner.Configuration(maxOutputBytes: 100_000)
      ) {
        for line in result.stdout.split(separator: "\n") {
          let path = String(line).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
          guard !path.isEmpty else { continue }
          let url = URL(fileURLWithPath: path)
          if FileManager.default.fileExists(atPath: url.path), !keychains.contains(url) {
            keychains.append(url)
          }
        }
      }
    }

    var combinedPEM: [String] = []
    var index = 0
    for keychain in keychains {
      let p12URL = tmpDir.appendingPathComponent("identities-\(index).p12")
      index += 1
      let export = try ProcessRunner.run(
        executable: "/usr/bin/security",
        arguments: ["export", "-k", keychain.path, "-t", "identities", "-f", "pkcs12", "-P", passphrase, "-o", p12URL.path]
      )
      guard export.succeeded, FileManager.default.fileExists(atPath: p12URL.path) else { continue }

      let pemOut = tmpDir.appendingPathComponent("identities-\(index).pem")
      let split = try ProcessRunner.run(
        executable: openssl,
        arguments: [
          "pkcs12", "-legacy", "-in", p12URL.path,
          "-clcerts", "-nodes", "-passin", "pass:\(passphrase)", "-out", pemOut.path,
        ]
      )
      if split.succeeded, let pemData = try? Data(contentsOf: pemOut) {
        combinedPEM.append(String(decoding: pemData, as: UTF8.self))
      }
      try? FileManager.default.removeItem(at: p12URL)
    }
    return combinedPEM
  }

  /// Parses a `security find-identity` line into its certificate hash and common name.
  static func parseIdentityLine(_ line: String) -> (hash: String, commonName: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasSuffix("\"") else { return nil }
    // e.g. "1) ABCDEF0123...  \"Apple Distribution: Name (TEAM)\""
    let parts = trimmed.split(separator: "\"", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count >= 2 else { return nil }
    let ident = String(parts[0])
    guard let hash = ident.split(separator: " ").last,
          hash.count == 40,
          hash.allSatisfy({ $0.isHexDigit }) else { return nil }
    return (String(hash), String(parts[1]))
  }

  static func teamID(fromCN commonName: String) -> String? {
    guard let open = commonName.lastIndex(of: "("),
          let close = commonName.lastIndex(of: ")"),
          open < close else { return nil }
    let team = String(commonName[commonName.index(after: open)..<close])
    return team.isEmpty ? nil : team
  }

  /// Returns the first certificate in `pem` whose DER SHA-1 equals `target`.
  static func matchCertificatePEM(bySHA1 target: String, in pem: String) throws -> String {
    let target = target.lowercased()
    for cert in splitCertificates(pem) {
      guard let der = derData(ofPEM: cert) else { continue }
      let digest = Insecure.SHA1.hash(data: der)
      let hex = digest.map { String(format: "%02x", $0) }.joined()
      if hex == target { return cert }
    }
    throw Error.identityNotFound
  }

  /// Returns the private key PEM whose RSA modulus matches `certPEM`.
  static func matchPrivateKey(certPEM: String, candidates: Data, openssl: String, tmpDir: URL) throws -> String {
    let certURL = tmpDir.appendingPathComponent("cert.pem")
    try Data(certPEM.utf8).write(to: certURL)
    let certModulus = try rsamodulus(ofCertificate: certURL, openssl: openssl)

    let content = String(decoding: candidates, as: UTF8.self)
    for (header, body) in splitPEMBlocks(content, headers: ["PRIVATE KEY", "RSA PRIVATE KEY"]) {
      let keyURL = tmpDir.appendingPathComponent("key.pem")
      try Data("-----BEGIN \(header)-----\n\(body)-----END \(header)-----\n".utf8).write(to: keyURL)
      let result = try ProcessRunner.run(
        executable: openssl,
        arguments: ["rsa", "-in", keyURL.path, "-noout", "-modulus"],
        configuration: ProcessRunner.Configuration(maxOutputBytes: 100_000)
      )
      try? FileManager.default.removeItem(at: keyURL)
      guard result.succeeded else { continue }
      let modulus = result.stdout.split(separator: "=").last.map(String.init) ?? ""
      if modulus == certModulus {
        return "-----BEGIN \(header)-----\n\(body)-----END \(header)-----\n"
      }
    }
    throw Error.keyNotFound
  }

  /// RSA modulus (hex) of a certificate's public key.
  static func rsamodulus(ofCertificate certURL: URL, openssl: String) throws -> String {
    let result = try ProcessRunner.run(
      executable: openssl,
      arguments: ["x509", "-in", certURL.path, "-noout", "-modulus"],
      configuration: ProcessRunner.Configuration(maxOutputBytes: 100_000)
    )
    guard result.succeeded, let modulus = result.stdout.split(separator: "=").last.map(String.init), !modulus.isEmpty else {
      throw Error.unsupported("Could not read the signing certificate's public key.")
    }
    return modulus
  }

  /// Splits a PEM document into `(header, base64Body)` blocks for the given headers.
  static func splitPEMBlocks(_ text: String, headers: [String]) -> [(String, String)] {
    var blocks: [(String, String)] = []
    var currentHeader: String?
    var bodyLines: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("-----BEGIN") {
        if let header = headers.first(where: { trimmed == "-----BEGIN \($0)-----" }) {
          currentHeader = header
          bodyLines = []
        } else {
          currentHeader = nil
        }
      } else if trimmed.hasPrefix("-----END") {
        if let header = currentHeader {
          blocks.append((header, bodyLines.joined(separator: "\n") + "\n"))
        }
        currentHeader = nil
      } else if currentHeader != nil {
        bodyLines.append(String(line))
      }
    }
    return blocks
  }

  /// Splits a PEM document into individual `-----BEGIN CERTIFICATE-----` blocks.
  static func splitCertificates(_ text: String) -> [String] {
    splitPEMBlocks(text, headers: ["CERTIFICATE", "X509 CERTIFICATE", "TRUSTED CERTIFICATE"]).map {
      "-----BEGIN \($0.0)-----\n\($0.1)-----END \($0.0)-----\n"
    }
  }

  /// Returns the DER bytes of a single PEM certificate.
  static func derData(ofPEM pem: String) -> Data? {
    let lines = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }
    return Data(base64Encoded: lines.joined())
  }

  /// Resolves an OpenSSL 3 binary, preferring the documented Homebrew install.
  static func resolveOpenSSL() throws -> String {
    for candidate in ["/opt/homebrew/bin/openssl", "/usr/local/bin/openssl"] {
      guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
      let result = try? ProcessRunner.run(
        executable: candidate,
        arguments: ["version"],
        configuration: ProcessRunner.Configuration(maxOutputBytes: 10_000)
      )
      if let result, result.succeeded, result.stdout.hasPrefix("OpenSSL 3") {
        return candidate
      }
    }
    throw Error.openSSLUnavailable
  }

  /// Selects the provisioning profile matching an identity by its certificate SHA-1
  /// (the same hash `security find-identity` reports).
  ///
  /// Xcode-managed profiles omit `ProfileType`, so the signing kind is inferred from the
  /// profile's `get-task-allow` entitlement (true = development, false = distribution),
  /// falling back to the provisioned-device list when that key is absent.
  public static func selectProfile(
    from profiles: [MobileProvisionParser.ProvisioningProfile],
    bundleID: String,
    kind: SigningKind,
    certSHA1: String,
    teamID: String?
  ) -> MobileProvisionParser.ProvisioningProfile? {
    let certSHA1 = certSHA1.lowercased()
    let matches = profiles.filter { profile in
      guard teamID == nil || profile.teamIdentifier.contains(teamID!) else { return false }
      guard applicationIdentifier(profile)?.hasSuffix("." + bundleID) == true else { return false }
      guard deviceProfile(profile, kind: kind) else { return false }
      if let devCerts = profile.plist["DeveloperCertificates"] as? [Data] {
        guard devCerts.contains(where: { SHA1(digest: $0) == certSHA1 }) else { return false }
      }
      return true
    }
    if matches.isEmpty { return nil }
    return matches.max { lhs, rhs in
      let l = lhs.expirationDate ?? .distantPast
      let r = rhs.expirationDate ?? .distantPast
      return l < r
    }
  }

  /// True when the profile matches the signing kind by its `get-task-allow`
  /// entitlement, falling back to the provisioned-device list when the key is absent.
  static func deviceProfile(
    _ profile: MobileProvisionParser.ProvisioningProfile,
    kind: SigningKind
  ) -> Bool {
    if let getTaskAllow = profile.entitlements["get-task-allow"] as? Bool {
      return getTaskAllow == (kind == .development)
    }
    let isDevelopment = !profile.provisionedDevices.isEmpty
    return isDevelopment == (kind == .development)
  }

  /// Returns the `.mobileprovision` file URL whose parsed profile matches the bundle
  /// ID, kind, and identity. This preserves the original signed CMS bytes so the
  /// imported profile can be embedded directly during signing.
  public static func selectProfileURL(
    from directory: URL,
    bundleID: String,
    kind: SigningKind,
    certSHA1: String,
    teamID: String?
  ) -> URL? {
    let entries = (try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )) ?? []
    let selected = entries.compactMap { url -> (URL, MobileProvisionParser.ProvisioningProfile)? in
      guard url.pathExtension == "mobileprovision",
            let profile = try? MobileProvisionParser.parse(at: url) else { return nil }
      return (url, profile)
    }
    guard let match = selectProfile(
      from: selected.map(\.1), bundleID: bundleID, kind: kind,
      certSHA1: certSHA1, teamID: teamID
    ) else { return nil }
    return selected.first(where: { $0.1.uuid == match.uuid })?.0
  }

  static func applicationIdentifier(_ profile: MobileProvisionParser.ProvisioningProfile) -> String? {
    profile.entitlements["application-identifier"] as? String
  }

  static func SHA1(digest: Data) -> String {
    Insecure.SHA1.hash(data: digest).map { String(format: "%02x", $0) }.joined()
  }
}
#endif
