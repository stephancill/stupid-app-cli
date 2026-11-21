import Foundation
import _CryptoExtras

/// What a signer receives for one signature: the CodeDirectory being signed and the DER
/// CMS signed attributes (a SET) whose bytes the RSA signature covers. The attributes
/// name only that CodeDirectory's digests, so a remote signer can check what it signs.
public struct CMSSignRequest: Sendable {
  public let codeDirectory: Data
  public let signedAttributes: Data

  public init(codeDirectory: Data, signedAttributes: Data) {
    self.codeDirectory = codeDirectory
    self.signedAttributes = signedAttributes
  }
}

/// Produces the RSA PKCS#1 v1.5 SHA-256 signature over a request's signed attributes.
/// Either the stored private key or a remote signer that holds it (a release session),
/// so a release can be signed on a host that never receives the key. `NativeCMS`
/// verifies every returned signature against the leaf certificate.
public struct CMSSigner: Sendable {
  public let sign: @Sendable (CMSSignRequest) throws -> Data

  public init(sign: @escaping @Sendable (CMSSignRequest) throws -> Data) {
    self.sign = sign
  }

  public static func privateKey(pem: String) -> CMSSigner {
    CMSSigner { request in
      let key = try _RSA.Signing.PrivateKey(pemRepresentation: pem)
      return try key.signature(for: request.signedAttributes, padding: .insecurePKCS1v1_5)
        .rawRepresentation
    }
  }
}
