import Crypto
import Foundation

enum NativeEmbeddedSignature {
  static func blob(magic: UInt32, payload: Data) -> Data {
    be32(magic) + be32(UInt32(payload.count + 8)) + payload
  }

  static func codeDirectory(
    executablePrefix: Data,
    identifier: String,
    teamID: String,
    specialSlots: [UInt32: Data],
    flags: UInt32,
    executableSegmentFlags: UInt64,
    executableSegmentBase: UInt64,
    executableSegmentLimit: UInt64
  ) -> Data {
    let identifierData = Data((identifier + "\0").utf8)
    let teamData = Data((teamID + "\0").utf8)
    let headerSize = 88
    let identifierOffset = headerSize
    let teamOffset = identifierOffset + identifierData.count
    let count = Int(specialSlots.keys.max() ?? 0)
    let specialStart = teamOffset + teamData.count
    let hashOffset = specialStart + count * 32
    let codeHashes = stride(from: 0, to: executablePrefix.count, by: 4096).map {
      Data(
        SHA256.hash(data: executablePrefix.subdata(in: $0..<min($0 + 4096, executablePrefix.count)))
      )
    }
    let length = hashOffset + codeHashes.count * 32
    var result = Data()
    result += be32(0xFADE_0C02)
    result += be32(UInt32(length))
    result += be32(0x0002_0400)
    result += be32(flags)
    result += be32(UInt32(hashOffset))
    result += be32(UInt32(identifierOffset))
    result += be32(UInt32(count))
    result += be32(UInt32(codeHashes.count))
    result += be32(UInt32(executablePrefix.count))
    result += Data([32, 2, 0, 12])
    result += be32(0)
    result += be32(0)
    result += be32(UInt32(teamOffset))
    result += be32(0)
    result += be64(UInt64(executablePrefix.count))
    result += be64(executableSegmentBase)
    result += be64(executableSegmentLimit)
    result += be64(executableSegmentFlags)
    result += identifierData
    result += teamData
    if count > 0 {
      for slot in stride(from: count, through: 1, by: -1) {
        result += specialSlots[UInt32(slot)] ?? Data(repeating: 0, count: 32)
      }
    }
    for hash in codeHashes { result += hash }
    return result
  }

  static func superBlob(_ blobs: [(UInt32, Data)]) -> Data {
    let indexSize = 12 + blobs.count * 8
    let length = indexSize + blobs.reduce(0) { $0 + $1.1.count }
    var result = be32(0xFADE_0CC0) + be32(UInt32(length)) + be32(UInt32(blobs.count))
    var offset = indexSize
    for (slot, data) in blobs {
      result += be32(slot) + be32(UInt32(offset))
      offset += data.count
    }
    for (_, data) in blobs { result += data }
    return result
  }

  static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
  private static func be32(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
  }
  private static func be64(_ value: UInt64) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
  }
}
