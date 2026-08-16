import Foundation
import Testing
@testable import BuildCore

/// Tests for native app-icon generation from a single square source PNG.
struct IconGeneratorTests {
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/source-icon.png")

    @Test("generates the full App Store icon set")
    func generatesIconSet() throws {
        let source = Self.fixtureURL
        #expect(FileManager.default.fileExists(atPath: source.path), "missing test fixture")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-icon-out-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }

        try IconGenerator.generate(sourceURL: source, outputDirectory: out)

        for spec in IconGenerator.specs {
            let url = out.appendingPathComponent(spec.name)
            #expect(FileManager.default.fileExists(atPath: url.path), "missing \(spec.name)")
            // Verify PNG signature and IHDR dimensions.
            let data = try Data(contentsOf: url)
            #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
            let width = Int(data[16]) << 24 | Int(data[17]) << 16 | Int(data[18]) << 8 | Int(data[19])
            let height = Int(data[20]) << 24 | Int(data[21]) << 16 | Int(data[22]) << 8 | Int(data[23])
            #expect(width == spec.pixels)
            #expect(height == spec.pixels)
        }
    }

    @Test("fails loudly on a missing source")
    func missingSource() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-icon-missing-\(UUID().uuidString).png")
        #expect(throws: IconGenerator.Error.self) {
            try IconGenerator.generate(sourceURL: url, outputDirectory: FileManager.default.temporaryDirectory)
        }
    }
}
