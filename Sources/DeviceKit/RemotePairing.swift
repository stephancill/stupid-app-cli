import Crypto
import Foundation
import _CryptoExtras

/// The remote-pairing protocol used to establish a CoreDevice network tunnel
/// from an existing saved remote pairing record. This is the network run path;
/// it performs Pair-Verify (X25519 + HKDF-SHA512 + ChaCha20-Poly1305) rather
/// than fresh SRP Pair-Setup.
public enum RemotePairing {
  public static let wireProtocolVersion: Int64 = 19
  static let magic = Data("RPPairing".utf8)

  // MARK: - TLV8 codec

  enum ComponentType: UInt8 {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case state = 0x06
    case error = 0x07
    case signature = 0x0A
    case info = 0x11
  }

  static func encodeTLV(_ components: [(type: ComponentType, data: Data)]) -> Data {
    var out = Data()
    for component in components {
      out.append(component.type.rawValue)
      out.append(UInt8(component.data.count))
      out.append(component.data)
    }
    return out
  }

  static func decodeTLV(_ data: Data) -> [ComponentType: Data] {
    var result: [ComponentType: Data] = [:]
    var cursor = 0
    while cursor + 2 <= data.count {
      guard let type = ComponentType(rawValue: data[cursor]) else {
        cursor += 1
        continue
      }
      let length = Int(data[cursor + 1])
      cursor += 2
      guard cursor + length <= data.count, length <= 256 else { break }
      result[type, default: Data()].append(data.subdata(in: cursor..<(cursor + length)))
      cursor += length
    }
    return result
  }

  // MARK: - Remote pairing record

  /// The saved remote pairing record for a device, stored as a binary plist
  /// with the host's Ed25519 key pair and the remote-unlock host key.
  public struct Record: Sendable {
    public var publicKey: Data
    public var privateKey: Data
    public var remoteUnlockHostKey: String

    static func load(from url: URL) throws -> Record {
      let data = try Data(contentsOf: url)
      let propertyList: Any
      do {
        propertyList = try PropertyListSerialization.propertyList(
          from: data, options: [], format: nil)
      } catch {
        throw Error.invalidRecord("\(url.lastPathComponent) is not a valid property list")
      }
      guard let dictionary = propertyList as? [String: Any] else {
        throw Error.invalidRecord("\(url.lastPathComponent) is not a dictionary")
      }
      func dataValue(_ key: String) throws -> Data {
        guard let value = dictionary[key] as? Data, !value.isEmpty else {
          throw Error.invalidRecord("\(url.lastPathComponent) is missing '\(key)'")
        }
        return value
      }
      let unlockKey: String
      if let string = dictionary["remote_unlock_host_key"] as? String {
        unlockKey = string
      } else if let data = dictionary["remote_unlock_host_key"] as? Data {
        unlockKey = String(decoding: data, as: UTF8.self)
      } else {
        throw Error.invalidRecord(
          "\(url.lastPathComponent) is missing 'remote_unlock_host_key'")
      }
      return Record(
        publicKey: try dataValue("public_key"),
        privateKey: try dataValue("private_key"),
        remoteUnlockHostKey: unlockKey
      )
    }
  }

  /// Discovers identifiers of saved remote pairing records in a pairing
  /// directory, mirroring pymobiledevice3's `iter_remote_paired_identifiers`.
  /// Only `remote_<identifier>.plist` files count; the `remote_udid.json` mapping
  /// file is intentionally not a pairing record.
  static func pairedIdentifiers(in pairingDirectory: URL) throws -> [String] {
    let contents = try FileManager.default.contentsOfDirectory(
      at: pairingDirectory, includingPropertiesForKeys: nil)
    var identifiers: [String] = []
    for url in contents {
      let name = url.lastPathComponent
      guard name.hasPrefix("remote_"), name.hasSuffix(".plist") else { continue }
      let remainder = String(name.dropFirst("remote_".count))
      let identifier = String(remainder.dropLast(".plist".count))
      if !identifier.isEmpty {
        identifiers.append(identifier)
      }
    }
    return identifiers
  }

  static func recordURL(identifier: String, in pairingDirectory: URL) -> URL {
    pairingDirectory.appendingPathComponent("remote_\(identifier).plist")
  }

  // MARK: - UDID mapping

  /// A JSON file mapping each remote-pairing identifier to the device UDID it
  /// was paired from. Written at pair time so wireless runs can resolve the
  /// requested `--udid` to exactly the matching remote record, instead of
  /// guessing across every record on the network (which is ambiguous when
  /// several Apple devices advertise).
  public static let udidMappingFileName = "remote_udid.json"

  static func udidMappingURL(in pairingDirectory: URL) -> URL {
    pairingDirectory.appendingPathComponent(Self.udidMappingFileName)
  }

  /// Loads the persisted `identifier -> udid` mapping, or an empty dictionary.
  static func loadUdidMapping(in pairingDirectory: URL) -> [String: String] {
    let url = udidMappingURL(in: pairingDirectory)
    guard
      let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data),
      let entries = object as? [String: String]
    else {
      return [:]
    }
    return entries
  }

  /// Atomically upserts `udid` into the mapping for `identifier`, preserving any
  /// previously persisted entries for other devices on this host.
  static func saveUdidMapping(
    identifier: String, udid: String, in pairingDirectory: URL
  ) throws {
    var entries = loadUdidMapping(in: pairingDirectory)
    entries[identifier] = udid
    let data = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
    try FileManager.default.createDirectory(
      at: pairingDirectory, withIntermediateDirectories: true)
    try data.write(to: udidMappingURL(in: pairingDirectory), options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: udidMappingURL(in: pairingDirectory).path)
  }

  /// Resolves the remote-pairing record identifiers that belong to a requested
  /// device UDID. When no persisted mapping is present (pre-mapping records), it
  /// returns the empty set so callers fall back to scanning every record.
  static func remoteIdentifiers(forUdid udid: String, in pairingDirectory: URL) -> [String] {
    loadUdidMapping(in: pairingDirectory).compactMap { identifier, mappedUDID in
      mappedUDID == udid ? identifier : nil
    }
  }

  /// Returns the remote-pairing identifiers to attempt for a requested UDID.
  ///
  /// Resolution is exact: a matching UDID-to-record mapping is required, and the
  /// function throws rather than guessing across other saved records. The previous
  /// scan-every-record fallback reintroduced the wrong-device ambiguity it was meant to
  /// remove, so pre-mapping records must be migrated with a fresh
  /// `stupid-app device pair --usb` instead of silently racing other devices.
  static func resolveIdentifiers(
    forRequestedUdid udid: String, in pairingDirectory: URL
  ) throws -> [String] {
    guard FileManager.default.fileExists(atPath: udidMappingURL(in: pairingDirectory).path) else {
      throw Error.noMappedRecord(udid)
    }
    let identifiers = remoteIdentifiers(forUdid: udid, in: pairingDirectory)
    guard !identifiers.isEmpty else {
      throw Error.noMappedRecord(udid)
    }
    return identifiers
  }

  // MARK: - Local pairing inventory

  /// One saved remote-pairing record, with its device UDID when a persisted mapping
  /// exists (`remote_udid.json`). Used by `stupid-app device list` to show the local
  /// device inventory and to surface records that still need a fresh pair to map them.
  public struct SavedPairing: Sendable, Equatable {
    public var identifier: String
    public var udid: String?

    public init(identifier: String, udid: String?) {
      self.identifier = identifier
      self.udid = udid
    }
  }

  /// Lists saved remote-pairing records in a pairing directory with their resolved
  /// device UDID (nil when the record predates the `remote_udid.json` mapping).
  public static func savedPairings(in pairingDirectory: URL) throws -> [SavedPairing] {
    let mapping = loadUdidMapping(in: pairingDirectory)
    let identifiers = try pairedIdentifiers(in: pairingDirectory)
    return identifiers.map { SavedPairing(identifier: $0, udid: mapping[$0]) }
  }

  // MARK: - Host identifier

  /// Reproduces pymobiledevice3's `generate_host_id()`: an uppercase UUIDv3
  /// (MD5 name-based) with the DNS namespace and the host name as the name.
  static func generateHostID(hostname: String) -> String {
    let dnsNamespace: [UInt8] = [
      0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1,
      0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8,
    ]
    var input = Data(dnsNamespace)
    input.append(Data(hostname.utf8))
    let digest = Insecure.MD5.hash(data: input)
    var bytes = Array(digest)
    bytes[6] = (bytes[6] & 0x0F) | 0x30
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }
    let formatted =
      "\(hex[0])\(hex[1])\(hex[2])\(hex[3])-\(hex[4])\(hex[5])-\(hex[6])\(hex[7])-\(hex[8])\(hex[9])-\(hex[10])\(hex[11])\(hex[12])\(hex[13])\(hex[14])\(hex[15])"
    return formatted.uppercased()
  }

  // MARK: - Errors

  public static func redact(detail: String, udid: String?) -> String {
    guard let udid, !udid.isEmpty else { return detail }
    return detail.replacingOccurrences(of: udid, with: "<device-udid>")
  }

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case invalidInput(String)
    case invalidRecord(String)
    case transport(String)
    case timedOut
    case invalidResponse(String)
    case pairing(String)
    case noMappedRecord(String)

    public var description: String {
      switch self {
      case .invalidInput(let detail):
        return "Remote-pairing input is invalid: \(detail)."
      case .invalidRecord(let detail):
        return "The remote pairing record is invalid: \(detail)."
      case .transport(let detail):
        return "The remote-pairing exchange failed: \(detail)."
      case .timedOut:
        return "The remote-pairing exchange timed out."
      case .invalidResponse(let detail):
        return "The remote-pairing response is invalid: \(detail)."
      case .pairing(let detail):
        return "Remote pairing failed: \(detail)."
      case .noMappedRecord(let udid):
        return "No remote-pairing record maps to device '\(udid)'. Re-run `stupid-app device pair --usb --udid <udid> --sudo <path>` to pair this device."
      }
    }
  }
}
