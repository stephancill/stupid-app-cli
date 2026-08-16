import Foundation
import PNG

/// Generates the App Store-required iOS app icon set from one square source PNG,
/// entirely in-process using the pure-Swift `swift-png` library. No host image
/// tooling (ImageMagick, Pillow, `sips`) is required. The output mirrors what Xcode's
/// asset catalog produces: concrete icon PNGs at every required size plus the 1024
/// marketing icon, written directly into the app bundle.
public enum IconGenerator {
    /// Icon filenames and their exact pixel size, matching Xcode's AppIcon.appiconset.
    public struct IconSpec: Sendable, Equatable {
        public var name: String
        public var pixels: Int

        public init(name: String, pixels: Int) {
            self.name = name
            self.pixels = pixels
        }
    }

    /// All icons App Store validation checks for, including the 1024 marketing icon.
    public static let specs: [IconSpec] = [
        IconSpec(name: "Icon-20.png", pixels: 20),
        IconSpec(name: "Icon-20@2x.png", pixels: 40),
        IconSpec(name: "Icon-20@3x.png", pixels: 60),
        IconSpec(name: "Icon-29.png", pixels: 29),
        IconSpec(name: "Icon-29@2x.png", pixels: 58),
        IconSpec(name: "Icon-29@3x.png", pixels: 87),
        IconSpec(name: "Icon-40.png", pixels: 40),
        IconSpec(name: "Icon-40@2x.png", pixels: 80),
        IconSpec(name: "Icon-40@3x.png", pixels: 120),
        IconSpec(name: "Icon-60@2x.png", pixels: 120),
        IconSpec(name: "Icon-60@3x.png", pixels: 180),
        IconSpec(name: "Icon-76.png", pixels: 76),
        IconSpec(name: "Icon-76@2x.png", pixels: 152),
        IconSpec(name: "Icon-83.5@2x.png", pixels: 167),
        IconSpec(name: "Icon-1024.png", pixels: 1024),
    ]

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case sourceMissing(String)
        case decodeFailed(String)
        case encodeFailed(String, String)

        public var description: String {
            switch self {
            case let .sourceMissing(path):
                return "The configured icon source '\(path)' does not exist."
            case let .decodeFailed(detail):
                return "Could not decode the source icon: \(detail)"
            case let .encodeFailed(name, detail):
                return "Could not generate app icon '\(name)': \(detail)"
            }
        }
    }

    /// Generates the full icon set into `outputDirectory` from one square source PNG.
    /// - Parameters:
    ///   - sourceURL: the square source PNG (any size; resized to every required size).
    ///   - outputDirectory: directory to write the generated `Icon-*.png` files into.
    public static func generate(sourceURL: URL, outputDirectory: URL) throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw Error.sourceMissing(sourceURL.path)
        }
        guard let source = try? PNG.Image.decompress(path: sourceURL.path) else {
            throw Error.decodeFailed("unsupported or corrupt PNG at \(sourceURL.path)")
        }

        // Force RGBA8 for a uniform pixel buffer we can resize.
        let (sourceWidth, sourceHeight) = (source.size.x, source.size.y)
        let sourcePixels = source.unpack(as: PNG.RGBA<UInt8>.self)

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for spec in specs {
            let resized = Self.resize(
                sourcePixels,
                width: sourceWidth,
                height: sourceHeight,
                to: spec.pixels
            )
            let image = PNG.Image(
                packing: resized,
                size: (x: spec.pixels, y: spec.pixels),
                layout: .init(format: .rgba8(palette: [], fill: nil))
            )
            let target = outputDirectory.appendingPathComponent(spec.name)
            do {
                guard try image.compress(path: target.path, level: 1) != nil else {
                    throw Error.encodeFailed(spec.name, "could not open destination")
                }
            } catch let error as Error {
                throw error
            } catch {
                throw Error.encodeFailed(spec.name, String(describing: error))
            }
        }
    }

    /// Area-average downscales an RGBA8 buffer to a square size. Correctly
    /// alpha-composites pixels so source transparency is preserved; upscaling uses
    /// nearest-neighbor (rare for icons but never distorts to a broken image).
    static func resize(_ pixels: [PNG.RGBA<UInt8>], width: Int, height: Int, to size: Int) -> [PNG.RGBA<UInt8>] {
        if size >= width, size >= height, size == width {
            return pixels
        }
        let scaleX = Double(width) / Double(size)
        let scaleY = Double(height) / Double(size)

        var output: [PNG.RGBA<UInt8>] = []
        output.reserveCapacity(size * size)

        if scaleX <= 1, scaleY <= 1 {
            // Downscale: area average with premultiplied alpha.
            for y in 0..<size {
                let sy0 = Int(Double(y) * scaleY)
                let sy1 = min(Int(Double(y + 1) * scaleY), height)
                for x in 0..<size {
                    let sx0 = Int(Double(x) * scaleX)
                    let sx1 = min(Int(Double(x + 1) * scaleX), width)
                    var r = 0.0, g = 0.0, b = 0.0, a = 0.0, weightSum = 0.0
                    for py in sy0..<sy1 {
                        for px in sx0..<sx1 {
                            let p = pixels[py * width + px]
                            let alpha = Double(p.a) / 255.0
                            let weight = alpha
                            r += Double(p.r) * weight
                            g += Double(p.g) * weight
                            b += Double(p.b) * weight
                            a += Double(p.a)
                            weightSum += weight
                        }
                    }
                    let count = Double((sy1 - sy0) * (sx1 - sx0))
                    if weightSum > 0 {
                        output.append(PNG.RGBA(
                            UInt8(max(0, min(255, Int(r / weightSum)))),
                            UInt8(max(0, min(255, Int(g / weightSum)))),
                            UInt8(max(0, min(255, Int(b / weightSum)))),
                            UInt8(max(0, min(255, Int(a / count))))
                        ))
                    } else {
                        output.append(PNG.RGBA(0, 0, 0, 0))
                    }
                }
            }
        } else {
            // Upscale: nearest-neighbor.
            for y in 0..<size {
                let sy = min(Int(Double(y) * scaleY), height - 1)
                for x in 0..<size {
                    let sx = min(Int(Double(x) * scaleX), width - 1)
                    output.append(pixels[sy * width + sx])
                }
            }
        }
        return output
    }
}
