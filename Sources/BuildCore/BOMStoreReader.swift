import Foundation

/// Minimal read-only BOMStore parser used by tests to verify `.car` structure.
public enum BOMStoreReader {
    public struct Parsed {
        public let namedBlocks: [String: Data]
        public let blocks: [Data]
        public let le16: (Data, Int) -> UInt16
        public let le32: (Data, Int) -> UInt32
    }

    public enum Error: Swift.Error {
        case badMagic
        case truncated
    }

    public static func parse(_ data: Data) throws -> Parsed {
        guard data.count >= 32, data.prefix(8) == Data("BOMStore".utf8) else {
            throw Error.badMagic
        }
        let be32: (Int) -> UInt32 = { offset in
            data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian
            }
        }
        let numberOfBlocks = be32(12)
        let indexOffset = be32(16)
        let indexLength = be32(20)
        let varsOffset = be32(24)
        let varsLength = be32(28)
        guard indexOffset + indexLength <= data.count, varsOffset + varsLength <= data.count else {
            throw Error.truncated
        }

        var namedBlocks: [String: Data] = [:]
        var allBlocks: [Data] = []
        let slotCount = (Int(indexLength) - 4) / 8
        allBlocks.reserveCapacity(slotCount)
        for id in 0..<slotCount {
            let blockOffset = be32(Int(indexOffset) + 4 + id * 8)
            let blockLength = be32(Int(indexOffset) + 8 + id * 8)
            guard blockOffset + blockLength <= data.count else { throw Error.truncated }
            allBlocks.append(Data(data[Int(blockOffset)..<Int(blockOffset + blockLength)]))
        }
        var pos = Int(varsOffset)
        let varCount = be32(pos); pos += 4
        guard varCount <= (Int(varsLength) - 4) / 5 else { throw Error.truncated }
        for _ in 0..<varCount {
            let blockID = be32(pos); pos += 4
            let nameLength = Int(data[pos]); pos += 1
            guard pos + nameLength <= Int(varsOffset) + Int(varsLength) else { throw Error.truncated }
            let name = String(decoding: data[pos..<pos + nameLength], as: UTF8.self)
            pos += nameLength
            guard blockID < numberOfBlocks else { throw Error.truncated }
            namedBlocks[name] = allBlocks[Int(blockID)]
        }

        let le16: (Data, Int) -> UInt16 = { d, o in
            d.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian
            }
        }
        let le32: (Data, Int) -> UInt32 = { d, o in
            d.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian
            }
        }
        return Parsed(namedBlocks: namedBlocks, blocks: allBlocks, le16: le16, le32: le32)
    }
}
