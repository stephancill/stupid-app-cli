import CLZFSE
import Foundation
import PNG
import XCTest

@testable import BuildCore

final class AssetCatalogWriterTests: XCTestCase {
  /// The reference `Assets.car` produced by macOS `actool` for a solid
  /// (0x80,0x40,0x20) 1024x1024 icon. Used as a structural golden file.
  private static let referenceCarURL: URL? = {
    let env = ProcessInfo.processInfo.environment["ASSET_CATALOG_REFERENCE"]
    guard let env, !env.isEmpty else { return nil }
    return URL(fileURLWithPath: env)
  }()

  private func makeCar() throws -> Data {
    let pixels = [PNG.RGBA<UInt8>](repeating: PNG.RGBA(0x80, 0x40, 0x20), count: 1024 * 1024)
    return try AssetCatalogWriter.makeCar(pixels: pixels, width: 1024, height: 1024)
  }

  func testContainerHeaderAndNamedBlocks() throws {
    let car = try makeCar()
    XCTAssertEqual(String(decoding: car.prefix(8), as: UTF8.self), "BOMStore")
    let bom = try BOMStoreReader.parse(car)
    XCTAssertEqual(bom.namedBlocks.count, 7)
    for name in [
      "CARHEADER", "RENDITIONS", "FACETKEYS", "APPEARANCEKEYS",
      "KEYFORMAT", "EXTENDED_METADATA", "BITMAPKEYS",
    ] {
      XCTAssertNotNil(bom.namedBlocks[name], "missing named block \(name)")
    }
  }

  func testCarHeaderFields() throws {
    let car = try makeCar()
    let bom = try BOMStoreReader.parse(car)
    let header = try XCTUnwrap(bom.namedBlocks["CARHEADER"])
    XCTAssertEqual(String(decoding: header.prefix(4), as: UTF8.self), "RATC")
    XCTAssertEqual(bom.le32(header, 16), 4)  // renditionCount
    XCTAssertEqual(bom.le32(header, 424), 2)  // schemaVersion
    XCTAssertEqual(bom.le32(header, 432), 2)  // keySemantics
  }

  func testKeyFormatShape() throws {
    let car = try makeCar()
    let bom = try BOMStoreReader.parse(car)
    let keyFormat = try XCTUnwrap(bom.namedBlocks["KEYFORMAT"])
    XCTAssertEqual(String(decoding: keyFormat.prefix(4), as: UTF8.self), "tmfk")
    XCTAssertEqual(bom.le32(keyFormat, 8), 9)  // 9 key tokens
  }

  func testIconRenditionsUseCompressedChunkedLZFSEPayloads() throws {
    let car = try makeCar()
    let bom = try BOMStoreReader.parse(car)

    // Locate the two Icon Image ISTC blocks by scanning RENDITIONS value
    // blocks: blocks 16 and 20 in the fixed layout.
    // The RENDITIONS tree leaf (block 3) entries reference value blocks.
    let renditions = try XCTUnwrap(bom.namedBlocks["RENDITIONS"])
    // Block 3 = leaf; its first entry points at value block 18, then 16, 14, 20.
    // Resolve via the block table through the KEYFORMAT block's slot index.
    // Simpler: reconstruct the layout by finding the MLEC payloads in the
    // block region using the CSI marker.
    let mlecCount = countOccurrences(of: Data("MLEC".utf8), in: car)
    let kcbcCount = countOccurrences(of: Data("KCBC".utf8), in: car)
    let compressedBlockCount = countOccurrences(of: Data("bvx2".utf8), in: car)
    let rawBlockCount = countOccurrences(of: Data("bvx-".utf8), in: car)
    XCTAssertGreaterThanOrEqual(mlecCount, 2, "expected at least two MLEC payloads")
    XCTAssertEqual(kcbcCount, 8, "expected four KCBC chunks per icon rendition")
    XCTAssertEqual(compressedBlockCount, 8, "expected one compressed LZFSE block per KCBC chunk")
    XCTAssertEqual(rawBlockCount, 0, "raw LZFSE blocks are rejected by App Store validation")
    _ = renditions
  }

  func testEveryLZFSEChunkDecodesToOriginalBGRARows() throws {
    let car = try makeCar()
    // Pixels are stored in BGRA byte order: blue, green, red, alpha.
    let expectedPixel = Data([0x20, 0x40, 0x80, 0xFF])
    var searchStart = car.startIndex
    var decodedChunkCount = 0

    while let marker = car.range(
      of: Data("KCBC".utf8), options: [], in: searchStart..<car.endIndex)
    {
      let chunkStart = marker.lowerBound
      let rowCount = Int(readLE32(car, at: chunkStart + 12))
      let encodedCount = Int(readLE32(car, at: chunkStart + 16))
      let streamStart = chunkStart + 20
      let streamEnd = streamStart + encodedCount
      let stream = car.subdata(in: streamStart..<streamEnd)
      let expectedCount = rowCount * 1024 * 4
      var decoded = Data(count: expectedCount)
      let decodedCount = decoded.withUnsafeMutableBytes { destination in
        stream.withUnsafeBytes { source in
          lzfse_decode_buffer(
            destination.bindMemory(to: UInt8.self).baseAddress,
            destination.count,
            source.bindMemory(to: UInt8.self).baseAddress,
            source.count,
            nil)
        }
      }

      XCTAssertEqual(decodedCount, expectedCount)
      XCTAssertEqual(decoded, repeated(expectedPixel, count: rowCount * 1024))
      decodedChunkCount += 1
      searchStart = streamEnd
    }

    XCTAssertEqual(decodedChunkCount, 8)
  }

  func testGeneratedCarPassesAssetutilWhenAvailable() throws {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
      throw XCTSkip("xcrun is unavailable; skipping macOS assetutil qualification")
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let carURL = directory.appendingPathComponent("Assets.car")
    try makeCar().write(to: carURL)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["assetutil", "--validate-file", carURL.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let diagnostic = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertEqual(process.terminationStatus, 0, diagnostic)
  }

  func testGeneratedCarMatchesActoolReferenceStructure() throws {
    guard let reference = Self.referenceCarURL,
      FileManager.default.fileExists(atPath: reference.path)
    else {
      throw XCTSkip("ASSET_CATALOG_REFERENCE not set; skipping differential check")
    }
    let generated = try makeCar()
    let refData = try Data(contentsOf: reference)

    let genBOM = try BOMStoreReader.parse(generated)
    let refBOM = try BOMStoreReader.parse(refData)

    XCTAssertEqual(genBOM.namedBlocks.keys.sorted(), refBOM.namedBlocks.keys.sorted())

    for name in genBOM.namedBlocks.keys.sorted() {
      let genBlock = try XCTUnwrap(genBOM.namedBlocks[name])
      let refBlock = try XCTUnwrap(refBOM.namedBlocks[name])
      if name == "CARHEADER" {
        var a = genBlock
        var b = refBlock
        a.replaceSubrange(12..<16, with: Data(count: 4))
        b.replaceSubrange(12..<16, with: Data(count: 4))
        XCTAssertEqual(a, b, "CARHEADER block differs from actool reference")
      } else {
        XCTAssertEqual(genBlock, refBlock, "block \(name) differs from actool reference")
      }
    }

    // Compare every structural block in the fixed layout. Blocks 16 and 20
    // are the Icon Image pixel payloads (uncompressed vs LZFSE by design);
    // everything else must match the actool reference exactly.
    let structuralIDs = [
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17, 18, 19, 21, 22, 23, 24,
    ]
    for id in structuralIDs {
      let genBlock = genBOM.blocks[id]
      let refBlock = refBOM.blocks[id]
      if id == 1 {
        var a = genBlock
        var b = refBlock
        a.replaceSubrange(12..<16, with: Data(count: 4))
        b.replaceSubrange(12..<16, with: Data(count: 4))
        XCTAssertEqual(a, b, "block \(id) differs from actool reference")
      } else {
        XCTAssertEqual(genBlock, refBlock, "block \(id) differs from actool reference")
      }
    }
  }

  private func countOccurrences(of needle: Data, in haystack: Data) -> Int {
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let range = haystack.range(of: needle, options: [], in: searchRange) {
      count += 1
      searchRange = range.upperBound..<haystack.endIndex
    }
    return count
  }

  private func readLE32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])
      | UInt32(data[offset + 1]) << 8
      | UInt32(data[offset + 2]) << 16
      | UInt32(data[offset + 3]) << 24
  }

  private func repeated(_ data: Data, count: Int) -> Data {
    var output = Data(capacity: data.count * count)
    for _ in 0..<count {
      output.append(data)
    }
    return output
  }
}
