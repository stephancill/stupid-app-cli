import Foundation
import PNG
import SDKCore

#if canImport(ImageIO)
  import CoreGraphics
  import ImageIO
#endif

/// Builds a tvOS app icon from one square source PNG. tvOS icons are layered image
/// stacks inside a brand-assets set (app icon, App Store icon, and top shelf images), which
/// only Xcode's `actool` compiles, so this needs an Xcode-present host. The back layer is
/// filled with the source's corner color and the front layer centers the source image.
public enum TVOSIconCatalog {
  static let brandAssetsName = "App Icon & Top Shelf Image"

  public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
    case requiresXcode
    case decodeFailed(String)
    case encodeFailed(String)
    case actoolFailed(String)

    public var description: String {
      switch self {
      case .requiresXcode:
        return "tvOS app icons are compiled with Xcode's actool and need an Xcode-present host."
      case .decodeFailed(let path):
        return "Could not decode the icon PNG at \(path)."
      case .encodeFailed(let detail):
        return "Could not write a tvOS icon layer: \(detail)."
      case .actoolFailed(let output):
        return "actool failed to compile the tvOS icon catalog.\n\(output)"
      }
    }
  }

  struct Slot {
    var directory: String
    var role: String
    var width: Int
    var height: Int
    var scales: [Int]
    var layered: Bool
  }

  static let slots: [Slot] = [
    Slot(
      directory: "App Icon.imagestack", role: "primary-app-icon", width: 400, height: 240,
      scales: [1, 2], layered: true),
    Slot(
      directory: "App Icon - App Store.imagestack", role: "primary-app-icon", width: 1280,
      height: 768, scales: [1], layered: true),
    Slot(
      directory: "Top Shelf Image.imageset", role: "top-shelf-image", width: 1920, height: 720,
      scales: [1, 2], layered: false),
    Slot(
      directory: "Top Shelf Image Wide.imageset", role: "top-shelf-image-wide", width: 2320,
      height: 720, scales: [1, 2], layered: false),
  ]

  /// Compiles `Assets.car` into `outputDirectory` and returns the Info.plist keys
  /// `actool` reports for the icon (`CFBundleIcons`, `TVTopShelfImage`).
  public static func compile(
    sourceURL: URL, outputDirectory: URL, platform: TargetPlatform,
    deploymentTarget: String, sdkInput: SDKInput
  ) throws -> [String: Sendable] {
    guard case .xcodeInPlace(let installation) = sdkInput else {
      throw Error.requiresXcode
    }
    guard let source = try? PNG.Image.decompress(path: sourceURL.path) else {
      throw Error.decodeFailed(sourceURL.path)
    }
    let pixels = source.unpack(as: PNG.RGBA<UInt8>.self)
    let size = (width: source.size.x, height: source.size.y)

    let work = FileManager.default.temporaryDirectory.appendingPathComponent(
      "stupid-app-tvos-icon-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let catalog = work.appendingPathComponent("Assets.xcassets", isDirectory: true)
    let brand = catalog.appendingPathComponent(
      "\(brandAssetsName).brandassets", isDirectory: true)
    try FileManager.default.createDirectory(at: brand, withIntermediateDirectories: true)
    try writeJSON(["info": info], to: catalog.appendingPathComponent("Contents.json"))

    var assets: [[String: Any]] = []
    for slot in slots {
      assets.append([
        "filename": slot.directory, "idiom": "tv", "role": slot.role,
        "size": "\(slot.width)x\(slot.height)",
      ])
      let slotDir = brand.appendingPathComponent(slot.directory, isDirectory: true)
      if slot.layered {
        let layers = ["Front", "Back"]
        try writeJSON(
          ["info": info, "layers": layers.map { ["filename": "\($0).imagestacklayer"] }],
          to: slotDir.appendingPathComponent("Contents.json"))
        for layer in layers {
          let layerDir = slotDir.appendingPathComponent("\(layer).imagestacklayer")
          try writeJSON(["info": info], to: layerDir.appendingPathComponent("Contents.json"))
          try writeImageSet(
            at: layerDir.appendingPathComponent("Content.imageset"), slot: slot,
            render: { width, height in
              layer == "Back"
                ? background(pixels: pixels, size: size, width: width, height: height)
                : foreground(pixels: pixels, size: size, width: width, height: height)
            })
        }
      } else {
        try writeImageSet(
          at: slotDir, slot: slot,
          render: { width, height in
            composite(pixels: pixels, size: size, width: width, height: height)
          })
      }
    }
    try writeJSON(
      ["info": info, "assets": assets], to: brand.appendingPathComponent("Contents.json"))

    let partialPlist = work.appendingPathComponent("partial.plist")
    var environment = ProcessInfo.processInfo.environment
    environment["DEVELOPER_DIR"] = installation.developerDirectory.path
    let result = try ProcessRunner.run(
      executable: "/usr/bin/xcrun",
      arguments: [
        "actool", catalog.path,
        "--compile", outputDirectory.path,
        "--platform", platform.sdkPlatformName,
        "--minimum-deployment-target", deploymentTarget,
        "--target-device", "tv",
        "--app-icon", brandAssetsName,
        "--output-partial-info-plist", partialPlist.path,
        "--errors", "--warnings",
        "--output-format", "human-readable-text",
      ],
      environment: environment
    )
    guard result.succeeded,
      let data = try? Data(contentsOf: partialPlist),
      let keys = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else {
      throw Error.actoolFailed(result.failureOutput + result.stdout)
    }
    return keys.mapValues { SendablePlistValue.wrap($0) }
  }

  private static var info: [String: Any] { ["author": "xcode", "version": 1] }

  private static func writeImageSet(
    at directory: URL, slot: Slot,
    render: (Int, Int) -> [PNG.RGBA<UInt8>]
  ) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var images: [[String: Any]] = []
    for scale in slot.scales {
      let width = slot.width * scale
      let height = slot.height * scale
      let name = "image@\(scale)x.png"
      try writePNG(
        render(width, height), width: width, height: height,
        to: directory.appendingPathComponent(name))
      images.append(["idiom": "tv", "scale": "\(scale)x", "filename": name])
    }
    try writeJSON(
      ["info": info, "images": images], to: directory.appendingPathComponent("Contents.json"))
  }

  /// Encodes RGBA8 pixels with ImageIO. The pure-Swift encoder takes minutes on the
  /// multi-megapixel top shelf images; tvOS icons already need Xcode, so macOS is given.
  private static func writePNG(
    _ pixels: [PNG.RGBA<UInt8>], width: Int, height: Int, to url: URL
  ) throws {
    #if canImport(ImageIO)
      var bytes = [UInt8]()
      bytes.reserveCapacity(width * height * 4)
      for pixel in pixels {
        bytes.append(pixel.r)
        bytes.append(pixel.g)
        bytes.append(pixel.b)
        bytes.append(pixel.a)
      }
      guard let provider = CGDataProvider(data: Data(bytes) as CFData),
        let image = CGImage(
          width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
        let destination = CGImageDestinationCreateWithURL(
          url as CFURL, "public.png" as CFString, 1, nil)
      else { throw Error.encodeFailed(url.lastPathComponent) }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else {
        throw Error.encodeFailed(url.lastPathComponent)
      }
    #else
      throw Error.requiresXcode
    #endif
  }

  private static func writeJSON(_ object: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
  }

  private static func cornerColor(_ pixels: [PNG.RGBA<UInt8>]) -> PNG.RGBA<UInt8> {
    let corner = pixels.first ?? PNG.RGBA(0, 0, 0, 255)
    return corner.a < 128 ? PNG.RGBA(0, 0, 0, 255) : PNG.RGBA(corner.r, corner.g, corner.b, 255)
  }

  static func background(
    pixels: [PNG.RGBA<UInt8>], size: (width: Int, height: Int), width: Int, height: Int
  ) -> [PNG.RGBA<UInt8>] {
    Array(repeating: cornerColor(pixels), count: width * height)
  }

  static func foreground(
    pixels: [PNG.RGBA<UInt8>], size: (width: Int, height: Int), width: Int, height: Int
  ) -> [PNG.RGBA<UInt8>] {
    let side = min(width, height)
    let scaled = IconGenerator.resize(pixels, width: size.width, height: size.height, to: side)
    var canvas = Array(repeating: PNG.RGBA<UInt8>(0, 0, 0, 0), count: width * height)
    let x0 = (width - side) / 2
    let y0 = (height - side) / 2
    for y in 0..<side {
      for x in 0..<side {
        canvas[(y0 + y) * width + x0 + x] = scaled[y * side + x]
      }
    }
    return canvas
  }

  static func composite(
    pixels: [PNG.RGBA<UInt8>], size: (width: Int, height: Int), width: Int, height: Int
  ) -> [PNG.RGBA<UInt8>] {
    let back = background(pixels: pixels, size: size, width: width, height: height)
    let front = foreground(pixels: pixels, size: size, width: width, height: height)
    return zip(back, front).map { b, f in
      let alpha = Int(f.a)
      func blend(_ top: UInt8, _ bottom: UInt8) -> UInt8 {
        UInt8((Int(top) * alpha + Int(bottom) * (255 - alpha)) / 255)
      }
      return PNG.RGBA(blend(f.r, b.r), blend(f.g, b.g), blend(f.b, b.b), 255)
    }
  }
}

/// Converts Foundation property-list values to `Sendable` ones for merging into a plan's
/// Info.plist dictionary.
enum SendablePlistValue {
  static func wrap(_ value: Any) -> Sendable {
    switch value {
    case let dictionary as [String: Any]:
      return dictionary.mapValues { wrap($0) } as [String: Sendable]
    case let array as [Any]:
      return array.map { wrap($0) } as [Sendable]
    case let string as String:
      return string
    case let number as NSNumber:
      return number
    case let data as Data:
      return data
    case let date as Date:
      return date
    default:
      return String(describing: value)
    }
  }
}
