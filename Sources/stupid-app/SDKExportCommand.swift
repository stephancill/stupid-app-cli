import ArgumentParser
import Foundation
import SDKCore

/// `stupid-app sdk export`: builds a device-only, checksummed Swift SDK bundle from an
/// installed Xcode installation. Runs on macOS; the artifact is imported elsewhere with
/// `stupid-app sdk import`.
struct SDKExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a device-only, checksummed Swift SDK bundle from an installed Xcode.",
        discussion: """
        Produces a tar.zst archive containing a SwiftPM artifact bundle for cross-compiling
        arm64-apple-ios on a host. Requires an installed Xcode on this Mac. The archive is
        imported on a supported host with `stupid-app sdk import`.

        A Linux host triple (e.g. x86_64-unknown-linux-gnu) downloads the pinned Linux
        darwin-tools archive. A macOS host triple (e.g. arm64-apple-macosx) stages the
        pinned Homebrew LLVM tools (`lld`, `llvm`, `zstd`) for the Xcode-absent path.
        """
    )

    @Option(name: .customLong("xcode"), help: "Path to an installed Xcode.app.")
    var xcodeApp: String = "/Applications/Xcode.app"

    @Option(name: .customLong("host"), help: "Host triple the bundle will run on, e.g. x86_64-unknown-linux-gnu or arm64-apple-macosx.")
    var hostTriple: String

    @Option(name: .customLong("target"), help: "Target triple (default arm64-apple-ios).")
    var targetTriple: String = "arm64-apple-ios"

    @Option(name: .customLong("output"), help: "Directory in which to write the archive.")
    var output: String = "."

    @Option(name: .customLong("scratch"), help: "Temporary working directory (defaults to a system temp dir).")
    var scratch: String?

    mutating func run() async throws {
        let xcodeURL = URL(fileURLWithPath: xcodeApp)
        guard FileManager.default.fileExists(atPath: xcodeURL.path) else {
            throw ExportError.xcodeMissing(xcodeURL)
        }

        let scratchURL: URL
        if let scratch {
            scratchURL = URL(fileURLWithPath: scratch)
            try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        } else {
            scratchURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("stupid-app-sdk-export-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: scratchURL) }

        let exporter = Exporter(options: .init(
            xcodeAppURL: xcodeURL,
            hostTriple: hostTriple,
            targetTriple: targetTriple,
            outputURL: URL(fileURLWithPath: output),
            scratchURL: scratchURL
        ))
        let archive = try exporter.run()
        print("Exported \(archive.path)")
        print("SHA-256: \(try SHA256.file(at: archive))")
    }
}