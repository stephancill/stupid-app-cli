import Foundation

/// Extracts the arm64 slice of a universal Mach-O. Embedded frameworks are signed per thin
/// binary, and XCFramework simulator slices usually ship arm64 and x86_64 together; the
/// x86_64 half is never run by an arm64 build.
public enum MachOThinner {
  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case malformed(String)
    case noARM64Slice(String)

    public var description: String {
      switch self {
      case .malformed(let detail): return "Malformed Mach-O while thinning: \(detail)."
      case .noARM64Slice(let name): return "'\(name)' has no arm64 slice."
      }
    }
  }

  private static let fatMagic: UInt32 = 0xCAFE_BABE
  private static let fat64Magic: UInt32 = 0xCAFE_BABF
  private static let thin64Magic: UInt32 = 0xFEED_FACF
  private static let arm64CPUType: UInt32 = 0x0100_000C

  /// Returns the thin arm64 Mach-O: `data` itself when already thin arm64, otherwise the
  /// arm64 slice of a universal binary. `name` labels errors.
  public static func arm64(_ data: Data, name: String) throws -> Data {
    let data = Data(data)
    guard data.count >= 8 else { throw Error.malformed("\(name) is truncated") }
    let magic = readBE32(data, 0)
    if readLE32(data, 0) == thin64Magic {
      guard readLE32(data, 4) == arm64CPUType else { throw Error.noARM64Slice(name) }
      return data
    }
    guard magic == fatMagic || magic == fat64Magic else {
      throw Error.malformed("\(name) is not a 64-bit or universal Mach-O")
    }
    let is64 = magic == fat64Magic
    let count = Int(readBE32(data, 4))
    let entrySize = is64 ? 32 : 20
    guard count > 0, 8 + count * entrySize <= data.count else {
      throw Error.malformed("\(name) has an invalid universal header")
    }
    for index in 0..<count {
      let entry = 8 + index * entrySize
      guard readBE32(data, entry) == arm64CPUType else { continue }
      let offset = is64 ? readBE64(data, entry + 8) : UInt64(readBE32(data, entry + 8))
      let size = is64 ? readBE64(data, entry + 16) : UInt64(readBE32(data, entry + 12))
      guard let start = Int(exactly: offset), let length = Int(exactly: size),
        start <= data.count, length <= data.count - start
      else { throw Error.malformed("\(name)'s arm64 slice exceeds the file") }
      let slice = data.subdata(in: start..<(start + length))
      guard slice.count >= 8, readLE32(slice, 0) == thin64Magic else {
        throw Error.malformed("\(name)'s arm64 slice is not a 64-bit Mach-O")
      }
      return slice
    }
    throw Error.noARM64Slice(name)
  }

  private static func readBE32(_ data: Data, _ offset: Int) -> UInt32 {
    data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian }
  }
  private static func readBE64(_ data: Data, _ offset: Int) -> UInt64 {
    data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian }
  }
  private static func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
    data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
  }
}
