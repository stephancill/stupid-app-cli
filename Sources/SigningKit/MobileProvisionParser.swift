import Foundation

/// Parses iOS `.mobileprovision` files: a CMS SignedData wrapping an XML plist. Only
/// the encapsulated content (the provisioning profile plist) is extracted here;
/// cryptographic verification of the CMS signature is out of scope for the initial
/// profile manager and is exercised via the signing kernel and ASC checks.
public enum MobileProvisionParser {
    public struct ProvisioningProfile {
        public var plist: [String: Any]
        /// Parsed `Entitlements` dictionary from the profile.
        public var entitlements: [String: Any]
        /// Parsed `ProvisionedDevices` identifiers (empty for App Store profiles).
        public var provisionedDevices: [String]
        /// `ApplicationIdentifierPrefix` values.
        public var applicationIdentifierPrefix: [String]
        /// `Name`.
        public var name: String?
        /// `ExpirationDate`.
        public var expirationDate: Date?
        /// `TeamIdentifier`.
        public var teamIdentifier: [String]
        /// `ProfileType` (e.g. "Distribution").
        public var profileType: String?
        /// `UUID`.
        public var uuid: String?

        public init(plist: [String: Any]) {
            self.plist = plist
            self.entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
            self.provisionedDevices = plist["ProvisionedDevices"] as? [String] ?? []
            self.applicationIdentifierPrefix = plist["ApplicationIdentifierPrefix"] as? [String] ?? []
            self.name = plist["Name"] as? String
            self.expirationDate = plist["ExpirationDate"] as? Date
            self.teamIdentifier = plist["TeamIdentifier"] as? [String] ?? []
            self.profileType = plist["ProfileType"] as? String
            self.uuid = plist["UUID"] as? String
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case notCMSData(String)
        case malformedCMS(String)
        case malformedPlist(String)

        public var description: String {
            switch self {
            case let .notCMSData(detail):
                return "The file is not a CMS/SignedData provisioning profile. \(detail)"
            case let .malformedCMS(detail):
                return "The provisioning profile CMS structure could not be parsed. \(detail)"
            case let .malformedPlist(detail):
                return "The provisioning profile payload is not a valid plist. \(detail)"
            }
        }
    }

    /// Parses a `.mobileprovision` file into its plist and key fields.
    public static func parse(_ data: Data) throws -> ProvisioningProfile {
        let eContent = try extractContent(data: data)
        guard let plist = try? PropertyListSerialization.propertyList(from: eContent, format: nil) as? [String: Any] else {
            throw Error.malformedPlist("payload is \(eContent.count) bytes")
        }
        return ProvisioningProfile(plist: plist)
    }

    public static func parse(at url: URL) throws -> ProvisioningProfile {
        guard let data = try? Data(contentsOf: url) else {
            throw Error.notCMSData("Could not read \(url.path).")
        }
        return try parse(data)
    }

    // MARK: - Minimal CMS/DER extraction

    /// Walks the CMS SignedData structure and returns the encapsulated content
    /// (the plist DER), without validating the signature.
    static func extractContent(data: Data) throws -> Data {
        var parser = DERReader(data)        // ContentInfo ::= SEQUENCE
        guard parser.readSequence() != nil else {
            throw Error.notCMSData("expected ContentInfo SEQUENCE")
        }
        // contentType OID
        guard let oid = parser.readOID() else {
            throw Error.notCMSData("expected contentType OID")
        }
        // content [0] EXPLICIT SignedData
        guard parser.peekTag() == 0xA0 else {
            throw Error.notCMSData("expected [0] explicit content")
        }
        _ = parser.readTagAndLength()
        // SignedData ::= SEQUENCE
        guard parser.readSequence() != nil else {
            throw Error.malformedCMS("expected SignedData SEQUENCE")
        }
        // version INTEGER
        guard parser.readInteger() != nil else {
            throw Error.malformedCMS("expected version")
        }
        // digestAlgorithms SET
        guard parser.readSet() != nil else {
            throw Error.malformedCMS("expected digestAlgorithms")
        }
        // encapContentInfo ::= SEQUENCE { eContentType OID, eContent [0] EXPLICIT OCTET STRING OPTIONAL }
        guard parser.readSequence() != nil else {
            throw Error.malformedCMS("expected encapContentInfo")
        }
        guard parser.readOID() != nil else {
            throw Error.malformedCMS("expected eContentType OID")
        }
        // eContent [0] EXPLICIT OCTET STRING
        guard parser.peekTag() == 0xA0 else {
            throw Error.malformedCMS("expected eContent [0]")
        }
        _ = parser.readTagAndLength()
        guard let content = parser.readOctetString() else {
            throw Error.malformedCMS("expected eContent OCTET STRING")
        }
        return content
    }
}

/// Minimal DER reader for the fixed CMS subset needed to unwrap a provisioning
/// profile. Kept deliberately small and strict.
private struct DERReader {
    let data: Data
    var index: Data.Index

    init(_ data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    mutating func peekTag() -> UInt8? {
        guard index < data.endIndex else { return nil }
        return data[index]
    }

    /// Reads a tag+length, returning the tag, and advances to just after the length.
    mutating func readTagAndLength() -> Int? {
        guard index < data.endIndex else { return nil }
        index += 1
        guard index < data.endIndex else { return nil }
        let first = data[index]
        index += 1
        if first & 0x80 == 0 {
            return Int(first)
        }
        let lengthBytes = Int(first & 0x7F)
        guard lengthBytes <= 4, index + lengthBytes <= data.endIndex else { return nil }
        var length = 0
        for _ in 0..<lengthBytes {
            length = (length << 8) | Int(data[index])
            index += 1
        }
        return length
    }

    /// For constructed/sequence types: reads the tag and length and returns the
    /// number of content bytes (advancing past the header).
    mutating func readSequence() -> Int? {
        guard peekTag() == 0x30 else { return nil }
        return readTagAndLength()
    }

    mutating func readSet() -> Int? {
        guard peekTag() == 0x31 else { return nil }
        guard let length = readTagAndLength(), index + length <= data.endIndex else { return nil }
        // Skip the entire SET: the digestAlgorithms set is not inspected.
        index += length
        return length
    }

    /// Reads an OBJECT IDENTIFIER and returns its first bytes (unused but validated).
    mutating func readOID() -> Data? {
        guard peekTag() == 0x06 else { return nil }
        guard let length = readTagAndLength(), index + length <= data.endIndex else { return nil }
        let oid = data[index..<(index + length)]
        index += length
        return Data(oid)
    }

    /// Reads an INTEGER (long form).
    mutating func readInteger() -> Data? {
        guard peekTag() == 0x02 else { return nil }
        guard let length = readTagAndLength(), index + length <= data.endIndex else { return nil }
        let value = data[index..<(index + length)]
        index += length
        return Data(value)
    }

    /// Reads an OCTET STRING and returns its payload.
    mutating func readOctetString() -> Data? {
        guard peekTag() == 0x04 else { return nil }
        guard let length = readTagAndLength(), index + length <= data.endIndex else { return nil }
        let value = data[index..<(index + length)]
        index += length
        return Data(value)
    }

    /// Returns the remaining bytes.
    mutating func readRemaining() -> Data? {
        guard index <= data.endIndex else { return nil }
        let remaining = data[index...]
        index = data.endIndex
        return Data(remaining)
    }
}