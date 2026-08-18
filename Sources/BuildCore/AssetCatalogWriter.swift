import CLZFSE
import Foundation
import PNG

/// Writes a CoreUI `.car` asset catalog for the app-icon subset, entirely in
/// Swift with no Apple tooling. The output mirrors what Xcode's `actool`
/// produces for a single 1024 marketing icon: the same BOMStore container,
/// CARHEADER/KEYFORMAT/EXTENDED_METADATA blocks, RENDITIONS/FACETKEYS/
/// APPEARANCEKEYS/BITMAPKEYS trees, and the Icon Image + MultiSized Image
/// rendition values.
///
/// The pixel payload uses CoreUI's LZFSE container (`MLEC`, compression type 4)
/// with `KCBC` row chunks. Each chunk uses a genuinely compressed LZFSE v2
/// stream produced by Apple's pinned reference implementation.
///
/// Format references:
/// - <https://dbg.re/posts/car-file-format/> (container, blocks, trees, CSI)
/// - <https://blog.timac.org/2018/1018-reverse-engineering-the-car-file-format/>
/// - bom.h from the open-source `bomutils` project (BOMStore container)
public enum AssetCatalogWriter {
  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case decodeFailed(String)
    case lzfseCompressionFailed
    case lzfseDidNotCompress
    case pixelBufferMismatch

    public var description: String {
      switch self {
      case .decodeFailed(let detail):
        return "Could not decode the icon source: \(detail)"
      case .lzfseCompressionFailed:
        return "Could not compress the app icon with LZFSE."
      case .lzfseDidNotCompress:
        return "LZFSE did not produce the compressed bvx2 stream required for the app icon."
      case .pixelBufferMismatch:
        return "The pixel buffer size does not match the declared icon dimensions."
      }
    }
  }

  // Attribute type IDs used by the reference key format.
  private enum KeyToken: UInt32 {
    case themeAppearance = 7
    case localization = 13
    case scale = 12
    case idiom = 15
    case subtype = 16
    case dimension2 = 9
    case identifier = 17
    case element = 1
    case part = 2
  }

  private static let keyFormatTokens: [UInt32] = [
    KeyToken.themeAppearance.rawValue,
    KeyToken.localization.rawValue,
    KeyToken.scale.rawValue,
    KeyToken.idiom.rawValue,
    KeyToken.subtype.rawValue,
    KeyToken.dimension2.rawValue,
    KeyToken.identifier.rawValue,
    KeyToken.element.rawValue,
    KeyToken.part.rawValue,
  ]

  // Fixed CoreUI identifiers for the AppIcon facet (observed in actool output).
  private static let elementAppIcon: UInt16 = 0x55
  private static let partIcon: UInt16 = 0xDC
  private static let partMultisized: UInt16 = 0xDA
  private static let identifierAppIcon: UInt16 = 0x1AC1

  private static let idiomPhone: UInt16 = 1
  private static let idiomPad: UInt16 = 2

  private static let blockSize = 0x1000
  private static let bitmapKeysBlockSize = 0x400

  // MARK: - Public API

  /// Generates `Assets.car` into `outputDirectory` from a square source PNG.
  /// - Parameters:
  ///   - sourceURL: the square source PNG (any size; resized to 1024x1024).
  ///   - outputDirectory: directory to write `Assets.car` into.
  public static func generate(sourceURL: URL, outputDirectory: URL) throws {
    guard let source = try? PNG.Image.decompress(path: sourceURL.path) else {
      throw Error.decodeFailed("unsupported or corrupt PNG at \(sourceURL.path)")
    }
    let (sourceWidth, sourceHeight) = (source.size.x, source.size.y)
    let sourcePixels = source.unpack(as: PNG.RGBA<UInt8>.self)
    let pixels = IconGenerator.resize(
      sourcePixels, width: sourceWidth, height: sourceHeight, to: 1024
    )
    let car = try makeCar(pixels: pixels, width: 1024, height: 1024)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    try car.write(to: outputDirectory.appendingPathComponent("Assets.car"))
  }

  /// Builds the full `.car` byte buffer for a 1024x1024 icon.
  static func makeCar(pixels: [PNG.RGBA<UInt8>], width: Int = 1024, height: Int = 1024) throws
    -> Data
  {
    guard pixels.count == width * height else {
      throw Error.pixelBufferMismatch
    }
    var bgra = Data(capacity: pixels.count * 4)
    // The rendition labels its pixel format "BGRA", so bytes must be blue, green, red,
    // alpha in memory order. Writing [a,r,g,b] here while labeling BGRA caused the app
    // icon to render with the alpha and blue channels swapped (a blue tint).
    for p in pixels {
      bgra.append(p.b)
      bgra.append(p.g)
      bgra.append(p.r)
      bgra.append(p.a)
    }
    return try buildCar(bgra: bgra, width: width, height: height)
  }

  // MARK: - Byte helpers

  private static func be16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
  private static func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
  private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
  private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

  private static func cstring(_ s: String, length: Int) -> Data {
    var data = Data(s.utf8)
    if data.count >= length {
      data = data.prefix(length - 1)
    }
    data.append(Data(count: length - data.count))
    return data
  }

  // MARK: - Blocks

  private static func treeHeader(
    root: UInt32, blockSize: UInt32, pathCount: UInt32,
    flags: UInt8, keySize: UInt32
  ) -> Data {
    var out = Data("tree".utf8)
    out.append(be32(1))  // version
    out.append(be32(root))  // root block
    out.append(be32(blockSize))
    out.append(be32(pathCount))
    out.append(Data([flags]))
    out.append(be32(keySize))
    out.append(be32(0))
    return out
  }

  /// A leaf node: isLeaf=1, count, forward/backward links, entries, then the
  /// 4-byte prefix and inline key copies that CoreUI actually reads.
  private static func treeLeaf(
    entries: [(value: UInt32, key: UInt32)],
    inlineKeys: [Data]
  ) -> Data {
    var out = Data()
    out.append(be16(1))
    out.append(be16(UInt16(entries.count)))
    out.append(be32(0))
    out.append(be32(0))
    for entry in entries {
      out.append(be32(entry.value))
      out.append(be32(entry.key))
    }
    if !inlineKeys.isEmpty {
      out.append(be32(0))
      for key in inlineKeys {
        out.append(key)
      }
    }
    return out
  }

  private static func carHeader(
    renditionCount: UInt32, timestamp: UInt32,
    coreUIVersion: UInt32 = 971
  ) -> Data {
    var out = Data("RATC".utf8)
    out.append(le32(coreUIVersion))  // coreuiVersion
    out.append(le32(17))  // storageVersion
    out.append(le32(timestamp))  // storageTimestamp
    out.append(le32(renditionCount))  // renditionCount
    out.append(cstring("@(#)PROGRAM:CoreUI  PROJECT:CoreUI-971.6", length: 128))
    out.append(cstring("Xcode 26.1.1 (17B100) via AssetCatalogSimulatorAgent", length: 256))
    out.append(Data(count: 16))  // uuid
    out.append(le32(0))  // associatedChecksum
    out.append(le32(2))  // schemaVersion
    out.append(le32(1))  // colorSpaceID
    out.append(le32(2))  // keySemantics
    return out
  }

  private static func extendedMetadata(
    platform: String, platformVersion: String,
    authoringTool: String
  ) -> Data {
    var out = Data("META".utf8)
    out.append(cstring("", length: 256))  // thinningArguments
    out.append(cstring(platformVersion, length: 256))  // deploymentPlatformVersion
    out.append(cstring(platform, length: 256))  // deploymentPlatform
    out.append(cstring(authoringTool, length: 256))  // authoringTool
    return out
  }

  private static func keyFormat() -> Data {
    var out = Data("tmfk".utf8)
    out.append(le32(0))  // version
    out.append(le32(UInt32(keyFormatTokens.count)))
    for token in keyFormatTokens {
      out.append(le32(token))
    }
    return out
  }

  /// 18-byte rendition key matching the KEYFORMAT token order.
  private static func renditionKey(
    idiom: UInt16, part: UInt16, dimension2: UInt16,
    identifier: UInt16 = identifierAppIcon
  ) -> Data {
    let values: [UInt16] = [
      0,  // themeAppearance
      0,  // localization
      1,  // scale
      idiom,
      0,  // subtype
      dimension2,
      identifier,
      elementAppIcon,
      part,
    ]
    return values.reduce(into: Data()) { $0.append(le16($1)) }
  }

  /// renditionkeytoken for the "AppIcon" facet.
  private static func facetValue(identifier: UInt16 = identifierAppIcon) -> Data {
    var out = Data()
    out.append(le16(0))  // cursorHotSpotX
    out.append(le16(0))  // cursorHotSpotY
    out.append(le16(3))  // numberOfAttributes
    out.append(le16(1))
    out.append(le16(elementAppIcon))  // Element
    out.append(le16(2))
    out.append(le16(partIcon))  // Part
    out.append(le16(17))
    out.append(le16(identifier))  // Identifier
    return out
  }

  private static func bitmapKeysValue() -> Data {
    var out = Data()
    out.append(le32(1))  // version
    out.append(le32(0))  // unknown
    out.append(le32(40))  // length
    out.append(le32(9))  // nkeys
    out.append(le32(0xFFFF_FFFF))
    out.append(le32(1))
    out.append(le32(2))
    out.append(le32(6))
    out.append(le32(1))
    out.append(le32(3))
    out.append(le32(0xFFFF_FFFF))
    out.append(le32(0xFFFF_FFFF))
    out.append(le32(0xFFFF_FFFF))
    return out
  }

  // MARK: - CSI rendition values

  private static func tlv(_ type: UInt32, _ payload: Data) -> Data {
    var out = Data()
    out.append(le32(type))
    out.append(le32(UInt32(payload.count)))
    out.append(payload)
    return out
  }

  private static func iconImageTLVs(width: Int, height: Int) -> Data {
    var out = Data()
    var slices = Data()
    slices.append(le32(1))  // count
    slices.append(le32(0))  // x
    slices.append(le32(0))  // y
    slices.append(le32(UInt32(width)))
    slices.append(le32(UInt32(height)))
    out.append(tlv(1001, slices))  // Slices

    var metrics = Data()
    metrics.append(le32(1))
    metrics.append(le32(0))
    metrics.append(le32(0))
    metrics.append(le32(0))
    metrics.append(le32(0))
    metrics.append(le32(0))
    metrics.append(le32(UInt32(width)))
    metrics.append(le32(UInt32(height)))
    out.append(tlv(1003, metrics))  // Metrics

    var blend = Data()
    blend.append(le32(0))
    blend.append(floatBits(1.0))
    out.append(tlv(1004, blend))  // BlendModeAndOpacity

    out.append(tlv(1006, le32(1)))  // EXIFOrientation
    out.append(tlv(1007, le32(0x1000)))  // unknown
    return out
  }

  private static func multisizedTLVs() -> Data {
    var out = Data()
    var blend = Data()
    blend.append(le32(0))
    blend.append(floatBits(0.0))
    out.append(tlv(1004, blend))
    out.append(tlv(1006, le32(1)))
    return out
  }

  private static func floatBits(_ f: Float) -> Data {
    var f = f
    return withUnsafeBytes(of: &f) { Data($0) }
  }

  private static func compressedLZFSEStream(_ data: Data) throws -> Data {
    var output = Data(count: data.count + 4096)
    let encodedCount = output.withUnsafeMutableBytes { destination in
      data.withUnsafeBytes { source in
        lzfse_encode_buffer(
          destination.bindMemory(to: UInt8.self).baseAddress,
          destination.count,
          source.bindMemory(to: UInt8.self).baseAddress,
          source.count,
          nil)
      }
    }
    guard encodedCount > 0 else {
      throw Error.lzfseCompressionFailed
    }
    output.removeSubrange(encodedCount..<output.count)
    guard output.starts(with: Data("bvx2".utf8)) else {
      throw Error.lzfseDidNotCompress
    }
    return output
  }

  /// CoreUI's chunked LZFSE bitmap payload. `actool` divides a 1024-row app
  /// icon into three 341-row chunks and one final row; preserve that layout.
  private static func iconImagePayload(bgra: Data, width: Int, height: Int) throws -> Data {
    let bytesPerRow = width * 4
    let rowsPerChunk = max(1, height / 3)
    var chunks: [(height: Int, stream: Data)] = []
    var row = 0
    while row < height {
      let chunkHeight = min(rowsPerChunk, height - row)
      let start = row * bytesPerRow
      let end = start + chunkHeight * bytesPerRow
      chunks.append((chunkHeight, try compressedLZFSEStream(bgra.subdata(in: start..<end))))
      row += chunkHeight
    }

    var out = Data("MLEC".utf8)
    out.append(le32(3))
    out.append(le32(4))
    out.append(le32(UInt32(chunks.count)))
    for chunk in chunks {
      out.append(Data("KCBC".utf8))
      out.append(le32(0))
      out.append(le32(0))
      out.append(le32(UInt32(chunk.height)))
      out.append(le32(UInt32(chunk.stream.count)))
      out.append(chunk.stream)
    }
    return out
  }

  private static func multisizedPayload(width: Int, height: Int) -> Data {
    var out = Data("SISM".utf8)
    out.append(le32(1))
    out.append(le32(1))
    out.append(le32(UInt32(width)))
    out.append(le32(UInt32(height)))
    out.append(le32(1))
    return out
  }

  /// One ISTC rendition value: 180-byte fixed prefix, bitmap lengths, TLV, payload.
  private static func csi(
    payload: Data, width: Int, height: Int, scaleFactor: UInt32,
    layout: UInt16, name: String, tlvs: Data,
    pixelFormat: Data, colorSpace: UInt32,
    renditionFlags: UInt32
  ) -> Data {
    var out = Data("ISTC".utf8)
    out.append(le32(1))  // version
    out.append(le32(renditionFlags))
    out.append(le32(UInt32(width)))
    out.append(le32(UInt32(height)))
    out.append(le32(scaleFactor))
    out.append(pixelFormat)
    out.append(le32(colorSpace))
    out.append(le32(0))  // modtime
    out.append(le16(layout))
    out.append(le16(0))
    out.append(cstring(name, length: 128))
    out.append(le32(UInt32(tlvs.count)))  // tvlLength
    out.append(le32(1))  // bitmapCount
    out.append(le32(0))  // reserved
    out.append(le32(UInt32(payload.count)))  // bitmap length
    out.append(tlvs)
    out.append(payload)
    return out
  }

  // MARK: - Container assembly

  private static func buildCar(
    bgra: Data, width: Int, height: Int,
    platform: String = "ios",
    platformVersion: String = "17.0",
    authoringTool: String =
      "@(#)PROGRAM:CoreThemeDefinition  PROJECT:CoreThemeDefinition-653.2  [IIO-2784.1.3.3]",
    timestamp: UInt32 = UInt32(Date().timeIntervalSince1970)
  ) throws -> Data {
    let iconPhone = csi(
      payload: try iconImagePayload(bgra: bgra, width: width, height: height), width: width,
      height: height,
      scaleFactor: 100, layout: 12, name: "icon-1024.png",
      tlvs: iconImageTLVs(width: width, height: height),
      pixelFormat: Data("BGRA".utf8), colorSpace: 1, renditionFlags: 0)
    let iconPad = csi(
      payload: try iconImagePayload(bgra: bgra, width: width, height: height), width: width,
      height: height,
      scaleFactor: 100, layout: 12, name: "icon-1024.png",
      tlvs: iconImageTLVs(width: width, height: height),
      pixelFormat: Data("BGRA".utf8), colorSpace: 1, renditionFlags: 0)
    let multiPhone = csi(
      payload: multisizedPayload(width: width, height: height),
      width: 0, height: 0, scaleFactor: 0, layout: 1010, name: "AppIcon",
      tlvs: multisizedTLVs(), pixelFormat: Data(count: 4), colorSpace: 0, renditionFlags: 0)
    let multiPad = csi(
      payload: multisizedPayload(width: width, height: height),
      width: 0, height: 0, scaleFactor: 0, layout: 1010, name: "AppIcon",
      tlvs: multisizedTLVs(), pixelFormat: Data(count: 4), colorSpace: 0, renditionFlags: 0)

    let keyIconPhone = renditionKey(idiom: idiomPhone, part: partIcon, dimension2: 1)
    let keyIconPad = renditionKey(idiom: idiomPad, part: partIcon, dimension2: 1)
    let keyMultiPhone = renditionKey(idiom: idiomPhone, part: partMultisized, dimension2: 0)
    let keyMultiPad = renditionKey(idiom: idiomPad, part: partMultisized, dimension2: 0)

    var blocks: [UInt32: Data] = [:]
    blocks[1] = carHeader(renditionCount: 4, timestamp: timestamp)
    blocks[2] = treeHeader(
      root: 3, blockSize: UInt32(blockSize), pathCount: 4,
      flags: 0, keySize: 18)
    let renditionsLeaf = treeLeaf(
      entries: [(18, 17), (16, 15), (14, 13), (20, 19)],
      inlineKeys: [keyMultiPhone, keyIconPhone, keyMultiPad, keyIconPad])
    blocks[3] = renditionsLeaf + Data(count: blockSize + 72 - renditionsLeaf.count)
    blocks[4] = treeHeader(
      root: 5, blockSize: UInt32(blockSize), pathCount: 1,
      flags: 0, keySize: 7)
    let facetsLeaf = treeLeaf(entries: [(11, 10)], inlineKeys: [Data("AppIcon\0".utf8)])
    blocks[5] = facetsLeaf + Data(count: blockSize + 7 - facetsLeaf.count)
    blocks[6] = treeHeader(
      root: 7, blockSize: UInt32(blockSize), pathCount: 1,
      flags: 0, keySize: 15)
    let appearanceLeaf = treeLeaf(entries: [(9, 8)], inlineKeys: [Data("UIAppearanceAny\0".utf8)])
    blocks[7] = appearanceLeaf + Data(count: blockSize + 15 - appearanceLeaf.count)
    blocks[8] = Data("UIAppearanceAny".utf8)
    blocks[9] = be16(0)
    blocks[10] = Data("AppIcon".utf8)
    blocks[11] = facetValue()
    blocks[12] = keyFormat()
    blocks[13] = keyMultiPad
    blocks[14] = multiPad
    blocks[15] = keyIconPhone
    blocks[16] = iconPhone
    blocks[17] = keyMultiPhone
    blocks[18] = multiPhone
    blocks[19] = keyIconPad
    blocks[20] = iconPad
    blocks[21] = extendedMetadata(
      platform: platform, platformVersion: platformVersion,
      authoringTool: authoringTool)
    blocks[22] = treeHeader(
      root: 23, blockSize: UInt32(bitmapKeysBlockSize), pathCount: 1,
      flags: 1, keySize: 0)
    let bitmapLeaf = treeLeaf(entries: [(24, UInt32(identifierAppIcon))], inlineKeys: [])
    blocks[23] = bitmapLeaf + Data(count: bitmapKeysBlockSize - bitmapLeaf.count)
    blocks[24] = bitmapKeysValue()

    let vars: [(String, UInt32)] = [
      ("CARHEADER", 1),
      ("RENDITIONS", 2),
      ("FACETKEYS", 4),
      ("APPEARANCEKEYS", 6),
      ("KEYFORMAT", 12),
      ("EXTENDED_METADATA", 21),
      ("BITMAPKEYS", 22),
    ]
    return assembleBOMStore(blocks: blocks, vars: vars)
  }

  /// Serializes blocks + named variables into a BOMStore container.
  private static func assembleBOMStore(blocks: [UInt32: Data], vars: [(String, UInt32)]) -> Data {
    let ids = blocks.keys.sorted()
    let headerSize = 0x200
    var body = Data(count: headerSize)
    var offsets: [UInt32: (offset: UInt32, length: UInt32)] = [:]
    var cursor = UInt32(headerSize)

    for id in ids {
      guard let data = blocks[id] else { continue }
      offsets[id] = (cursor, UInt32(data.count))
      body.append(data)
      cursor += UInt32(data.count)
    }

    var varsData = Data()
    varsData.append(be32(UInt32(vars.count)))
    for (name, id) in vars {
      let nameBytes = Data(name.utf8)
      varsData.append(be32(id))
      varsData.append(UInt8(nameBytes.count))
      varsData.append(nameBytes)
    }
    let varsOffset = cursor
    body.append(varsData)
    cursor += UInt32(varsData.count)

    let slotCount: UInt32 = 256
    var index = Data()
    index.append(be32(slotCount))
    for i in 0..<slotCount {
      let o = offsets[UInt32(i)] ?? (0, 0)
      index.append(be32(o.offset))
      index.append(be32(o.length))
    }
    index.append(be32(0))  // free list count
    let indexOffset = cursor
    body.append(index)
    cursor += UInt32(index.count)

    var header = Data("BOMStore".utf8)
    header.append(be32(1))  // version
    header.append(be32(UInt32(blocks.count)))  // numberOfBlocks
    header.append(be32(indexOffset))
    header.append(be32(UInt32(index.count)))
    header.append(be32(varsOffset))
    header.append(be32(UInt32(varsData.count)))
    body.replaceSubrange(0..<header.count, with: header)
    return body
  }
}
