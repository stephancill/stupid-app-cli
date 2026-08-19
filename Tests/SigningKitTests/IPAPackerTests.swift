import Foundation
import SigningKit
import Testing

/// IPA packaging fixture tests. Build a real (small) `.app` bundle in a temp directory,
/// package it into an IPA, and verify the `Payload/` shape and symlink handling via the
/// real `zip`/`unzip`. Enabled only when the system tools exist (Linux hosts may omit
/// them), so the suite stays usable everywhere.
struct IPAPackerTests {
    private static let zipAvailable =
        FileManager.default.isExecutableFile(atPath: "/usr/bin/zip")
        && FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip")

    @Test("packages and verifies a Payload/App.app IPA", .enabled(if: zipAvailable))
    func packagesAndVerifies() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("AcceptanceApp.app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try Data("executable".utf8).write(to: app.appendingPathComponent("AcceptanceApp"))
        try Data("png".utf8).write(to: app.appendingPathComponent("Resources/AppIcon.png"))

        let output = root.appendingPathComponent("release")
        let ipa = try IPAPacker.pack(appBundle: app, product: "AcceptanceApp", outputDirectory: output)

        // `pack` runs the re-read verification internally and throws on failure, so a
        // successful return implies the Payload/ shape and forbidden-outside checks passed.
        #expect(FileManager.default.fileExists(atPath: ipa.path))
        #expect(ipa.lastPathComponent == "AcceptanceApp.ipa")
    }

    @Test("rejects an app bundle whose symlink escapes the bundle", .enabled(if: zipAvailable))
    func rejectsEscapingSymlink() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("App.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: app.appendingPathComponent("executable"))
        try FileManager.default.createSymbolicLink(
            atPath: app.appendingPathComponent("escape").path,
            withDestinationPath: "/etc/passwd"
        )

        let output = root.appendingPathComponent("release")
        #expect(throws: IPAPacker.Error.self) {
            _ = try IPAPacker.pack(appBundle: app, product: "App", outputDirectory: output)
        }
    }

    @Test("fails loudly when the app bundle is missing")
    func missingBundle() throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: IPAPacker.Error.self) {
            _ = try IPAPacker.pack(
                appBundle: root.appendingPathComponent("Missing.app"),
                product: "Missing",
                outputDirectory: root
            )
        }
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-ipa-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
