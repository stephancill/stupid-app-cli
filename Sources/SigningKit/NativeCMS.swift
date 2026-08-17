import Crypto
import Foundation
import X509
import _CryptoExtras

public enum NativeCMS {
  public struct VerificationResult: Equatable, Sendable {
    public let certificateCount: Int
    public let cdhash: Data
    public let hasTimestamp: Bool
    public let certificateCommonNames: [String?]
    public let certificateExtensions: [[String: Data]]
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)
    case verificationFailed(String)

    public var description: String {
      switch self {
      case .malformed(let detail): return "Malformed native CMS: \(detail)."
      case .unsupported(let detail): return "Unsupported native CMS: \(detail)."
      case .verificationFailed(let detail): return "Native CMS verification failed: \(detail)."
      }
    }
  }

  private static let dataOID = "1.2.840.113549.1.7.1"
  private static let signedDataOID = "1.2.840.113549.1.7.2"
  private static let sha256OID = "2.16.840.1.101.3.4.2.1"
  private static let rsaEncryptionOID = "1.2.840.113549.1.1.1"
  private static let contentTypeOID = "1.2.840.113549.1.9.3"
  private static let messageDigestOID = "1.2.840.113549.1.9.4"
  private static let cdhashPlistOID = "1.2.840.113635.100.9.1"
  private static let cdhashesOID = "1.2.840.113635.100.9.2"
  private static let timestampTokenOID = "1.2.840.113549.1.9.16.2.14"

  public static func sign(
    codeDirectory: Data,
    privateKeyPEM: String,
    leafCertificatePEM: String,
    intermediateCertificatePEM: String,
    rootCertificatePEM: String
  ) throws -> Data {
    let leafDER = try mapDER { try NativeDER.pemDER(leafCertificatePEM) }
    let intermediateDER = try mapDER { try NativeDER.pemDER(intermediateCertificatePEM) }
    let rootDER = try mapDER { try NativeDER.pemDER(rootCertificatePEM) }
    let certificate = try Certificate(derEncoded: ArraySlice(leafDER))
    guard let publicKey = _RSA.Signing.PublicKey(certificate.publicKey) else {
      throw Error.unsupported("signing certificate does not contain an RSA key")
    }
    let privateKey = try _RSA.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
    guard privateKey.publicKey.derRepresentation == publicKey.derRepresentation else {
      throw Error.verificationFailed("private key does not match leaf certificate")
    }

    let identity = try certificateIdentity(leafDER)
    let digest = Data(SHA256.hash(data: codeDirectory))
    let signedAttributes = try attributes(codeDirectoryDigest: digest)
    let signatureInput = NativeDER.node(0x31, signedAttributes)
    let signature = try privateKey.signature(for: signatureInput, padding: .insecurePKCS1v1_5)
      .rawRepresentation
    let digestAlgorithm = try algorithm(sha256OID, includeNull: false)
    let signerInfo = NativeDER.sequence([
      NativeDER.integer(1),
      NativeDER.sequence([identity.issuer, NativeDER.integer(identity.serial)]),
      digestAlgorithm,
      NativeDER.node(0xA0, signedAttributes),
      try algorithm(rsaEncryptionOID, includeNull: true),
      NativeDER.octetString(signature),
    ])
    let signedData = NativeDER.sequence([
      NativeDER.integer(1),
      NativeDER.set([digestAlgorithm]),
      NativeDER.sequence([try NativeDER.oid(dataOID)]),
      NativeDER.node(
        0xA0,
        [leafDER, intermediateDER, rootDER].sorted { $0.lexicographicallyPrecedes($1) }
          .reduce(Data(), +)),
      NativeDER.set([signerInfo]),
    ])
    return NativeDER.sequence([
      try NativeDER.oid(signedDataOID),
      NativeDER.node(0xA0, signedData),
    ])
  }

  public static func verify(
    cms: Data,
    codeDirectory: Data,
    trustedRootCertificatesPEM: [String]
  ) throws -> VerificationResult {
    let parsed = try parseCMS(cms)
    let digest = Data(SHA256.hash(data: codeDirectory))
    guard parsed.messageDigest == digest else {
      throw Error.verificationFailed("message-digest attribute differs from CodeDirectory")
    }
    guard parsed.cdhash == digest else {
      throw Error.verificationFailed("Apple cdhash attribute differs from CodeDirectory")
    }
    guard parsed.plistCDHash == Data(digest.prefix(20)) else {
      throw Error.verificationFailed("Apple cdhash plist differs from CodeDirectory")
    }
    guard !parsed.hasTimestamp else {
      throw Error.verificationFailed("RFC 3161 timestamp attribute is present")
    }

    let leaf = try Certificate(derEncoded: ArraySlice(parsed.certificates[0]))
    guard let key = _RSA.Signing.PublicKey(leaf.publicKey) else {
      throw Error.unsupported("CMS signer is not RSA")
    }
    let signature = _RSA.Signing.RSASignature(rawRepresentation: parsed.signature)
    guard
      key.isValidSignature(signature, for: parsed.signatureInput, padding: .insecurePKCS1v1_5)
    else {
      throw Error.verificationFailed("RSA-SHA256 signature is invalid")
    }
    let orderedCertificates = try verifyChain(
      certificates: parsed.certificates, trustedRootsPEM: trustedRootCertificatesPEM)
    let metadata = try orderedCertificates.map(certificateMetadata)
    return VerificationResult(
      certificateCount: orderedCertificates.count,
      cdhash: digest,
      hasTimestamp: false,
      certificateCommonNames: metadata.map(\.commonName),
      certificateExtensions: metadata.map(\.extensions))
  }

  public static func certificateCommonName(_ pem: String) throws -> String {
    let der = try mapDER { try NativeDER.pemDER(pem) }
    let identity = try certificateIdentity(der)
    guard let commonName = try findCommonName(in: identity.subject) else {
      throw Error.malformed("leaf certificate subject has no common name")
    }
    return commonName
  }

  private struct ParsedCMS {
    let certificates: [Data]
    let signatureInput: Data
    let signature: Data
    let messageDigest: Data
    let cdhash: Data
    let plistCDHash: Data
    let hasTimestamp: Bool
  }

  private static func parseCMS(_ data: Data) throws -> ParsedCMS {
    do {
      var offset = 0
      let contentInfo = try NativeDER.parseOne(data, offset: &offset)
      guard offset == data.count, contentInfo.tag == 0x30 else {
        throw Error.malformed("ContentInfo is invalid")
      }
      let contentFields = try NativeDER.children(contentInfo)
      guard contentFields.count == 2, try oidString(contentFields[0]) == signedDataOID,
        contentFields[1].tag == 0xA0
      else {
        throw Error.malformed("ContentInfo is not SignedData")
      }
      var signedOffset = 0
      let signedData = try NativeDER.parseOne(contentFields[1].content, offset: &signedOffset)
      guard signedOffset == contentFields[1].content.count, signedData.tag == 0x30 else {
        throw Error.malformed("SignedData is invalid")
      }
      let fields = try NativeDER.children(signedData)
      guard fields.count == 5, fields[1].tag == 0x31, fields[2].tag == 0x30, fields[3].tag == 0xA0,
        fields[4].tag == 0x31
      else {
        throw Error.malformed("SignedData field shape is invalid")
      }
      let digestAlgorithms = try NativeDER.children(fields[1])
      guard digestAlgorithms.count == 1,
        try algorithmOID(digestAlgorithms[0]) == sha256OID
      else { throw Error.unsupported("SignedData digest algorithm is not SHA-256") }
      let encap = try NativeDER.children(fields[2])
      guard encap.count == 1, try oidString(encap[0]) == dataOID else {
        throw Error.malformed("CMS content is not detached id-data")
      }
      var certOffset = 0
      var certificates = [Data]()
      while certOffset < fields[3].content.count {
        let certificate = try NativeDER.parseOne(fields[3].content, offset: &certOffset)
        guard certificate.tag == 0x30 else {
          throw Error.unsupported("certificate choice is not X.509")
        }
        certificates.append(certificate.encoded)
      }
      guard certificates.count >= 2 else {
        throw Error.malformed("leaf and WWDR intermediate certificates are required")
      }
      let signers = try NativeDER.children(fields[4])
      guard signers.count == 1 else { throw Error.unsupported("expected exactly one CMS signer") }
      let signer = try NativeDER.children(signers[0])
      guard signer.count == 6 || signer.count == 7, signer[3].tag == 0xA0,
        signer[5].tag == 0x04, signer.count == 6 || signer[6].tag == 0xA1
      else {
        throw Error.malformed("SignerInfo field shape is invalid")
      }
      guard try algorithmOID(signer[2]) == sha256OID,
        try algorithmOID(signer[4]) == rsaEncryptionOID
      else { throw Error.unsupported("SignerInfo is not RSA-SHA256") }
      let signerIdentity = try NativeDER.children(signer[1])
      guard signerIdentity.count == 2, signerIdentity[1].tag == 0x02 else {
        throw Error.malformed("SignerIdentifier is invalid")
      }
      guard
        let leafIndex = try certificates.firstIndex(where: {
          let identity = try certificateIdentity($0)
          return identity.issuer == signerIdentity[0].encoded
            && identity.serial == signerIdentity[1].content
        })
      else {
        throw Error.verificationFailed("SignerIdentifier does not match an embedded certificate")
      }
      let leaf = certificates.remove(at: leafIndex)
      certificates.insert(leaf, at: 0)
      let attrs = try parseAttributes(signer[3].content)
      let hasUnsignedTimestamp =
        try signer.count == 7
        ? containsAttribute(oid: timestampTokenOID, in: signer[6].content) : false
      return ParsedCMS(
        certificates: certificates,
        signatureInput: NativeDER.node(0x31, signer[3].content),
        signature: signer[5].content,
        messageDigest: attrs.messageDigest,
        cdhash: attrs.cdhash,
        plistCDHash: attrs.plistCDHash,
        hasTimestamp: attrs.hasTimestamp || hasUnsignedTimestamp)
    } catch let error as Error { throw error } catch {
      throw Error.malformed("ASN.1 decoding failed")
    }
  }

  private static func attributes(codeDirectoryDigest digest: Data) throws -> Data {
    var plist = try PropertyListSerialization.data(
      fromPropertyList: ["cdhashes": [Data(digest.prefix(20))]], format: .xml, options: 0)
    if plist.last != 0x0A { plist.append(0x0A) }
    let digestValue = NativeDER.sequence([
      try NativeDER.oid(sha256OID),
      NativeDER.octetString(digest),
    ])
    let values: [Data] = [
      try attribute(contentTypeOID, NativeDER.oid(dataOID)),
      try attribute(messageDigestOID, NativeDER.octetString(digest)),
      try attribute(cdhashPlistOID, NativeDER.octetString(plist)),
      try attribute(cdhashesOID, digestValue),
    ]
    return values.sorted { $0.lexicographicallyPrecedes($1) }.reduce(Data(), +)
  }

  private static func attribute(_ oid: String, _ value: Data) throws -> Data {
    NativeDER.sequence([try NativeDER.oid(oid), NativeDER.set([value])])
  }

  private static func parseAttributes(_ data: Data) throws -> (
    messageDigest: Data, cdhash: Data, plistCDHash: Data, hasTimestamp: Bool
  ) {
    var offset = 0
    var values = [String: NativeDER.Node]()
    var previous: Data?
    while offset < data.count {
      let attribute = try NativeDER.parseOne(data, offset: &offset)
      if let previous, !previous.lexicographicallyPrecedes(attribute.encoded) {
        throw Error.malformed("signed attributes are not canonical")
      }
      previous = attribute.encoded
      let fields = try NativeDER.children(attribute)
      guard fields.count == 2, fields[1].tag == 0x31 else {
        throw Error.malformed("signed attribute is invalid")
      }
      let oid = try oidString(fields[0])
      guard values[oid] == nil else { throw Error.malformed("duplicate signed attribute") }
      let setValues = try NativeDER.children(fields[1])
      guard setValues.count == 1 else { throw Error.unsupported("multi-valued signed attribute") }
      values[oid] = setValues[0]
    }
    guard let contentType = values[contentTypeOID], try oidString(contentType) == dataOID,
      let messageDigest = values[messageDigestOID], messageDigest.tag == 0x04,
      let cdhashValue = values[cdhashesOID], cdhashValue.tag == 0x30,
      let plistValue = values[cdhashPlistOID], plistValue.tag == 0x04
    else { throw Error.malformed("required signed attributes are missing") }
    let cdhashFields = try NativeDER.children(cdhashValue)
    guard cdhashFields.count == 2, try oidString(cdhashFields[0]) == sha256OID,
      cdhashFields[1].tag == 0x04
    else {
      throw Error.malformed("Apple cdhash attribute is invalid")
    }
    let plistObject = try PropertyListSerialization.propertyList(
      from: plistValue.content, options: [], format: nil)
    guard let plist = plistObject as? [String: Any], let hashes = plist["cdhashes"] as? [Data],
      hashes.count == 1
    else {
      throw Error.malformed("Apple cdhash plist attribute is invalid")
    }
    return (
      messageDigest.content, cdhashFields[1].content, hashes[0], values[timestampTokenOID] != nil
    )
  }

  private static func containsAttribute(oid expected: String, in data: Data) throws -> Bool {
    var offset = 0
    while offset < data.count {
      let attribute = try NativeDER.parseOne(data, offset: &offset)
      let fields = try NativeDER.children(attribute)
      guard fields.count == 2 else { throw Error.malformed("unsigned attribute is invalid") }
      if try oidString(fields[0]) == expected { return true }
    }
    return false
  }

  private static func verifyChain(certificates: [Data], trustedRootsPEM: [String]) throws -> [Data]
  {
    let parsed = try certificates.map {
      (data: $0, certificate: try Certificate(derEncoded: ArraySlice($0)))
    }
    guard let leaf = parsed.first else { throw Error.malformed("CMS certificate set is empty") }
    var ordered = [leaf]
    var remaining = Array(parsed.dropFirst())
    while ordered.last!.certificate.issuer != ordered.last!.certificate.subject {
      guard
        let next = remaining.firstIndex(where: {
          $0.certificate.subject == ordered.last!.certificate.issuer
        })
      else {
        break
      }
      ordered.append(remaining.remove(at: next))
    }
    guard remaining.isEmpty else {
      throw Error.verificationFailed("CMS certificate set does not form one chain")
    }
    let chain = ordered.map(\.certificate)
    let now = Date()
    for certificate in chain
    where now < certificate.notValidBefore || now > certificate.notValidAfter {
      throw Error.verificationFailed("certificate is outside its validity period")
    }
    for index in 0..<(chain.count - 1) {
      guard chain[index].issuer == chain[index + 1].subject,
        chain[index + 1].publicKey.isValidSignature(chain[index].signature, for: chain[index])
      else { throw Error.verificationFailed("embedded certificate chain signature is invalid") }
    }
    guard !trustedRootsPEM.isEmpty else {
      throw Error.verificationFailed("no trusted Apple root certificate was supplied")
    }
    let roots = try trustedRootsPEM.map { try Certificate(pemEncoded: $0) }
    let chainEnd = chain.last!
    guard
      roots.contains(where: {
        (chainEnd.subject == $0.subject && chainEnd.publicKey == $0.publicKey)
          || (chainEnd.issuer == $0.subject
            && $0.publicKey.isValidSignature(chainEnd.signature, for: chainEnd))
      })
    else {
      throw Error.verificationFailed(
        "certificate chain does not terminate at a supplied trusted root")
    }
    return ordered.map(\.data)
  }

  private static func certificateIdentity(_ der: Data) throws -> (
    issuer: Data, serial: Data, subject: NativeDER.Node
  ) {
    var offset = 0
    let certificate = try NativeDER.parseOne(der, offset: &offset)
    let certificateFields = try NativeDER.children(certificate)
    guard offset == der.count, certificateFields.count == 3 else {
      throw Error.malformed("X.509 certificate shape is invalid")
    }
    let tbs = try NativeDER.children(certificateFields[0])
    let base = tbs.first?.tag == 0xA0 ? 1 : 0
    guard tbs.count > base + 5, tbs[base].tag == 0x02 else {
      throw Error.malformed("X.509 TBSCertificate is invalid")
    }
    return (tbs[base + 2].encoded, tbs[base].content, tbs[base + 4])
  }

  private static func certificateMetadata(_ der: Data) throws -> (
    commonName: String?, extensions: [String: Data]
  ) {
    var offset = 0
    let certificate = try NativeDER.parseOne(der, offset: &offset)
    let certificateFields = try NativeDER.children(certificate)
    guard certificateFields.count == 3 else {
      throw Error.malformed("X.509 certificate shape is invalid")
    }
    let tbs = try NativeDER.children(certificateFields[0])
    let base = tbs.first?.tag == 0xA0 ? 1 : 0
    guard tbs.count > base + 4 else { throw Error.malformed("X.509 TBSCertificate is invalid") }
    var extensions = [String: Data]()
    if let wrapper = tbs.first(where: { $0.tag == 0xA3 }) {
      var wrapperOffset = 0
      let sequence = try NativeDER.parseOne(wrapper.content, offset: &wrapperOffset)
      for item in try NativeDER.children(sequence) {
        let fields = try NativeDER.children(item)
        guard fields.count == 2 || fields.count == 3, let value = fields.last, value.tag == 0x04
        else {
          throw Error.malformed("X.509 extension is invalid")
        }
        extensions[try oidString(fields[0])] = value.content
      }
    }
    return (try findCommonName(in: tbs[base + 4]), extensions)
  }

  static func oidString(content: Data) throws -> String {
    try oidString(NativeDER.Node(tag: 0x06, encoded: Data(), content: content))
  }

  private static func findCommonName(in node: NativeDER.Node) throws -> String? {
    for set in try NativeDER.children(node) {
      for sequence in try NativeDER.children(set) {
        let fields = try NativeDER.children(sequence)
        guard fields.count == 2 else { continue }
        if try oidString(fields[0]) == "2.5.4.3" {
          return String(data: fields[1].content, encoding: .utf8)
        }
      }
    }
    return nil
  }

  private static func algorithm(_ oid: String, includeNull: Bool) throws -> Data {
    NativeDER.sequence(
      includeNull ? [try NativeDER.oid(oid), NativeDER.null()] : [try NativeDER.oid(oid)])
  }

  private static func algorithmOID(_ node: NativeDER.Node) throws -> String {
    guard node.tag == 0x30, let oid = try NativeDER.children(node).first else {
      throw Error.malformed("algorithm identifier is invalid")
    }
    return try oidString(oid)
  }

  private static func oidString(_ node: NativeDER.Node) throws -> String {
    guard node.tag == 0x06, let first = node.content.first else {
      throw Error.malformed("object identifier is invalid")
    }
    var components = [UInt64(first / 40), UInt64(first % 40)]
    var value: UInt64 = 0
    for byte in node.content.dropFirst() {
      let (shifted, overflow) = value.multipliedReportingOverflow(by: 128)
      let (next, addOverflow) = shifted.addingReportingOverflow(UInt64(byte & 0x7F))
      guard !overflow, !addOverflow else { throw Error.malformed("object identifier overflows") }
      value = next
      if byte & 0x80 == 0 {
        components.append(value)
        value = 0
      }
    }
    guard value == 0 else { throw Error.malformed("object identifier is truncated") }
    return components.map(String.init).joined(separator: ".")
  }

  private static func mapDER<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch { throw Error.malformed("PEM or DER input is invalid") }
  }
}
