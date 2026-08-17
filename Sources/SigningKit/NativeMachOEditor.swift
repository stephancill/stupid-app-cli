import Foundation

enum NativeMachOEditor {
  struct Layout {
    let prefix: Data
    let signatureOffset: Int
    let executableSegmentBase: UInt64
    let executableSegmentLimit: UInt64
  }

  enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case malformed(String)
    case unsupported(String)

    var description: String {
      switch self {
      case .malformed(let detail): return "Malformed native signing Mach-O: \(detail)."
      case .unsupported(let detail): return "Unsupported native signing Mach-O: \(detail)."
      }
    }
  }

  static func layout(executable: Data, signatureSize: Int) throws -> Layout {
    var data = Data(executable)
    guard data.count >= 32, read32(data, 0) == 0xFEED_FACF, read32(data, 4) == 0x0100_000C,
      read32(data, 12) == 2
    else { throw Error.unsupported("expected thin little-endian ARM64 MH_EXECUTE") }
    let commandCount = Int(read32(data, 16))
    let commandBytes = Int(read32(data, 20))
    let commandsEnd = try add(32, commandBytes)
    guard commandsEnd <= data.count else { throw Error.malformed("load commands exceed the file") }
    var commandOffset = 32
    var signatureCommandOffset: Int?
    var oldSignature: (offset: Int, size: Int)?
    var linkeditCommandOffset: Int?
    var linkedit: (offset: Int, size: Int)?
    var executableSegment: (base: UInt64, limit: UInt64)?
    var firstSectionOffset = data.count
    for _ in 0..<commandCount {
      guard commandOffset <= commandsEnd - 8 else {
        throw Error.malformed("load command is truncated")
      }
      let command = read32(data, commandOffset)
      let size = Int(read32(data, commandOffset + 4))
      guard size >= 8, size.isMultiple(of: 8), commandOffset <= commandsEnd - size else {
        throw Error.malformed("load command size is invalid")
      }
      if command == 0x1D {
        guard size == 16, signatureCommandOffset == nil else {
          throw Error.unsupported("invalid or duplicate LC_CODE_SIGNATURE")
        }
        signatureCommandOffset = commandOffset
        oldSignature = (Int(read32(data, commandOffset + 8)), Int(read32(data, commandOffset + 12)))
      } else if command == 0x19 {
        guard size >= 72 else { throw Error.malformed("LC_SEGMENT_64 is truncated") }
        let name = segmentName(data, commandOffset + 8)
        let fileOffset = try int(read64(data, commandOffset + 40))
        let fileSize = try int(read64(data, commandOffset + 48))
        let sectionCount = Int(read32(data, commandOffset + 64))
        guard 72 + sectionCount * 80 <= size else {
          throw Error.malformed("segment sections exceed load command")
        }
        for index in 0..<sectionCount {
          let sectionOffset = try int(read32(data, commandOffset + 72 + index * 80 + 48))
          if sectionOffset > 0 { firstSectionOffset = min(firstSectionOffset, sectionOffset) }
        }
        if name == "__LINKEDIT" {
          guard linkeditCommandOffset == nil else {
            throw Error.unsupported("multiple __LINKEDIT segments")
          }
          linkeditCommandOffset = commandOffset
          linkedit = (fileOffset, fileSize)
        } else if name == "__TEXT" {
          guard executableSegment == nil else {
            throw Error.unsupported("multiple __TEXT segments")
          }
          let (limit, overflow) = UInt64(fileOffset).addingReportingOverflow(UInt64(fileSize))
          guard !overflow else { throw Error.malformed("__TEXT range overflows") }
          executableSegment = (UInt64(fileOffset), limit)
        }
      }
      commandOffset += size
    }
    guard commandOffset == commandsEnd, let linkeditCommandOffset, let linkedit,
      let executableSegment
    else {
      throw Error.malformed("load commands, __TEXT, or __LINKEDIT are invalid")
    }
    guard linkedit.offset <= data.count, linkedit.size <= data.count - linkedit.offset,
      linkedit.offset + linkedit.size == data.count
    else { throw Error.unsupported("__LINKEDIT must be final file data") }

    let unsignedEnd: Int
    if let oldSignature {
      guard oldSignature.offset >= linkedit.offset,
        oldSignature.size <= data.count - oldSignature.offset,
        oldSignature.offset + oldSignature.size == data.count
      else { throw Error.unsupported("existing signature must be final data") }
      unsignedEnd = oldSignature.offset
    } else {
      guard commandsEnd <= firstSectionOffset - 16,
        data[commandsEnd..<(commandsEnd + 16)].allSatisfy({ $0 == 0 })
      else {
        throw Error.unsupported("insufficient zero load-command space for LC_CODE_SIGNATURE")
      }
      unsignedEnd = data.count
      write32(&data, 16, UInt32(commandCount + 1))
      write32(&data, 20, UInt32(commandBytes + 16))
      write32(&data, commandsEnd, 0x1D)
      write32(&data, commandsEnd + 4, 16)
      signatureCommandOffset = commandsEnd
    }
    data.removeSubrange(unsignedEnd..<data.count)
    let padding = (16 - data.count % 16) % 16
    data.append(Data(repeating: 0, count: padding))
    let signatureOffset = data.count
    guard signatureOffset <= UInt32.max, signatureSize <= UInt32.max else {
      throw Error.unsupported("signature offsets exceed Mach-O fields")
    }
    let newLinkeditSize = try add(signatureOffset - linkedit.offset, signatureSize)
    let vmSize = ((newLinkeditSize + 16_383) / 16_384) * 16_384
    write64(&data, linkeditCommandOffset + 32, UInt64(vmSize))
    write64(&data, linkeditCommandOffset + 48, UInt64(newLinkeditSize))
    write32(&data, signatureCommandOffset! + 8, UInt32(signatureOffset))
    write32(&data, signatureCommandOffset! + 12, UInt32(signatureSize))
    return Layout(
      prefix: data,
      signatureOffset: signatureOffset,
      executableSegmentBase: executableSegment.base,
      executableSegmentLimit: executableSegment.limit)
  }

  static func embed(executable: Data, signature: Data) throws -> Data {
    let layout = try layout(executable: executable, signatureSize: signature.count)
    return layout.prefix + signature
  }

  private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
    data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
  }
  private static func read64(_ data: Data, _ offset: Int) -> UInt64 {
    data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian }
  }
  private static func write32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
    withUnsafeBytes(of: value.littleEndian) {
      data.replaceSubrange(offset..<(offset + 4), with: $0)
    }
  }
  private static func write64(_ data: inout Data, _ offset: Int, _ value: UInt64) {
    withUnsafeBytes(of: value.littleEndian) {
      data.replaceSubrange(offset..<(offset + 8), with: $0)
    }
  }
  private static func segmentName(_ data: Data, _ offset: Int) -> String {
    String(decoding: data[offset..<(offset + 16)].prefix(while: { $0 != 0 }), as: UTF8.self)
  }
  private static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw Error.malformed("integer overflow") }
    return result
  }
  private static func int<T: BinaryInteger>(_ value: T) throws -> Int {
    guard let result = Int(exactly: value) else { throw Error.malformed("integer is too large") }
    return result
  }
}
