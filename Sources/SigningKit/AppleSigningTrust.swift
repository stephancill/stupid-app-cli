import Crypto
import Foundation
import X509

public enum AppleSigningTrust {
  public struct Chain: Equatable, Sendable {
    public let intermediateCertificatePEM: String
    public let rootCertificatePEM: String

    public init(intermediateCertificatePEM: String, rootCertificatePEM: String) {
      self.intermediateCertificatePEM = intermediateCertificatePEM
      self.rootCertificatePEM = rootCertificatePEM
    }
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case resourceMissing(String)
    case invalidResource(String)
    case resourceChecksumMismatch(String, actual: String)
    case unsupportedLeafIssuer

    public var description: String {
      switch self {
      case .resourceMissing(let name):
        return "The bundled Apple signing certificate '\(name)' is missing. Reinstall stupid-app."
      case .invalidResource(let name):
        return "The bundled Apple signing certificate '\(name)' is invalid. Reinstall stupid-app."
      case .resourceChecksumMismatch(let name, let actual):
        return
          "The bundled Apple signing certificate '\(name)' has unexpected SHA-256 \(actual). Reinstall stupid-app."
      case .unsupportedLeafIssuer:
        return
          "The signing identity does not chain to the qualified Apple WWDR G3 intermediate. Update stupid-app for current Apple certificate-chain support."
      }
    }
  }

  private struct PinnedCertificate {
    let name: String
    let sha256: String
  }

  private static let intermediate = PinnedCertificate(
    name: "AppleWWDRCAG3",
    sha256: "dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f")
  private static let root = PinnedCertificate(
    name: "AppleIncRootCertificate",
    sha256: "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024")

  public static func chain(forLeafCertificatePEM leafPEM: String) throws -> Chain {
    let chain = try loadQualifiedChain()
    let leaf: Certificate
    let intermediateCertificate: Certificate
    do {
      leaf = try Certificate(pemEncoded: leafPEM)
      intermediateCertificate = try Certificate(pemEncoded: chain.intermediateCertificatePEM)
    } catch {
      throw Error.unsupportedLeafIssuer
    }
    guard leaf.issuer == intermediateCertificate.subject,
      intermediateCertificate.publicKey.isValidSignature(leaf.signature, for: leaf)
    else {
      throw Error.unsupportedLeafIssuer
    }
    return chain
  }

  public static func validateQualifiedChain() throws {
    _ = try loadQualifiedChain()
  }

  static func loadQualifiedChain(now: Date = Date()) throws -> Chain {
    let intermediatePEM = try load(intermediate)
    let rootPEM = try load(root)
    let intermediateCertificate: Certificate
    let rootCertificate: Certificate
    do {
      intermediateCertificate = try Certificate(pemEncoded: intermediatePEM)
      rootCertificate = try Certificate(pemEncoded: rootPEM)
    } catch {
      throw Error.invalidResource("Apple signing trust chain")
    }
    guard intermediateCertificate.issuer == rootCertificate.subject,
      rootCertificate.publicKey.isValidSignature(
        intermediateCertificate.signature, for: intermediateCertificate),
      rootCertificate.subject == rootCertificate.issuer,
      rootCertificate.publicKey.isValidSignature(rootCertificate.signature, for: rootCertificate),
      now >= intermediateCertificate.notValidBefore,
      now <= intermediateCertificate.notValidAfter,
      now >= rootCertificate.notValidBefore,
      now <= rootCertificate.notValidAfter
    else {
      throw Error.invalidResource("Apple signing trust chain")
    }
    return Chain(
      intermediateCertificatePEM: intermediatePEM,
      rootCertificatePEM: rootPEM)
  }

  private static func load(_ pin: PinnedCertificate) throws -> String {
    guard let url = Bundle.module.url(forResource: pin.name, withExtension: "pem") else {
      throw Error.resourceMissing(pin.name)
    }
    let pem: String
    let der: Data
    do {
      pem = try String(contentsOf: url, encoding: .utf8)
      der = try NativeDER.pemDER(pem)
    } catch {
      throw Error.invalidResource(pin.name)
    }
    let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    guard digest == pin.sha256 else {
      throw Error.resourceChecksumMismatch(pin.name, actual: digest)
    }
    return pem
  }
}
