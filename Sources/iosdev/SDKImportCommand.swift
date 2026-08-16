import ArgumentParser
import Foundation
import SDKCore

/// `iosdev sdk import`: validates a checksummed SDK archive and registers it with
/// SwiftPM via `swift sdk install` after an atomic, verified activation.
struct SDKImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Validate and install an iosdev SDK archive.",
        discussion: """
        Verifies the archive checksum, extracts it into a temporary sibling directory with
        strict path validation, verifies every declared file checksum and the host Swift /
        host triple compatibility, then registers the bundle with `swift sdk install`.
        """
    )

    @Argument(help: "Path to the SDK archive produced by iosdev-sdk-export (.tar.zst).")
    var archive: String

    @Option(name: .customLong("expected-sha256"), help: "Expected archive SHA-256 to verify against.")
    var expectedSHA256: String?

    @Option(name: .customLong("swift"), help: "Path to the host `swift` executable.")
    var swiftPath: String = "swift"

    mutating func run() async throws {
        let archiveURL = URL(fileURLWithPath: archive)
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw ImportError.archiveUnreadable(archive)
        }

        // 1. Verify the archive checksum.
        let actual = try SHA256.file(at: archiveURL)
        if let expectedSHA256 {
            guard actual.lowercased() == expectedSHA256.lowercased() else {
                throw ImportError.checksumMismatch(computed: actual, expected: expectedSHA256)
            }
        } else {
            print("Archive SHA-256: \(actual)")
        }

        // 2. Host compatibility probe.
        let host = try HostInfo.detect(swiftPath: swiftPath)

        // 3. Safe extract into a temporary sibling directory.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("iosdev-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        try await SafeArchive.extract(archive: archiveURL, to: scratch)

        // 4. Locate the artifact bundle.
        let bundleName = try findArtifactBundle(in: scratch)
        let bundleURL = scratch.appendingPathComponent(bundleName)

        // 5. Read and verify the manifest.
        let manifestURL = bundleURL.appendingPathComponent("sdk-manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else {
            throw ImportError.missingManifest(bundleName)
        }
        let manifest = try SDKManifest.decode(manifestData)
        try verifyFiles(in: bundleURL, against: manifest)
        try verifyHost(host, against: manifest)

        // 6. Register with SwiftPM. `swift sdk install` copies the bundle into the
        //    SwiftPM SDKs directory, so the validated bundle is what gets installed.
        print("Installing SDK bundle '\(bundleName)' via `swift sdk install`...")
        let install = Process()
        install.executableURL = URL(fileURLWithPath: HostInfo.resolveExecutable(swiftPath))
        install.arguments = ["sdk", "install", bundleURL.path]
        try install.run()
        install.waitUntilExit()
        guard install.terminationStatus == 0 else {
            throw ImportError.installFailed(bundleName)
        }
        print("Installed SDK '\(manifest.generator)' for \(manifest.targetTriple) on \(host.triple).")
    }

    private func findArtifactBundle(in scratch: URL) throws -> String {
        let contents = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        guard let bundle = contents.first(where: { $0.hasSuffix(".artifactbundle") }) else {
            throw ImportError.noArtifactBundle
        }
        // There should be exactly one artifact bundle per archive.
        let bundles = contents.filter { $0.hasSuffix(".artifactbundle") }
        guard bundles.count == 1 else {
            throw ImportError.multipleBundles(bundles)
        }
        return bundle
    }

    private func verifyFiles(in bundleURL: URL, against manifest: SDKManifest) throws {
        var errors: [String] = []
        for (relative, expected) in manifest.files.sorted(by: { $0.key < $1.key }) {
            let fileURL = bundleURL.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                errors.append("missing \(relative)")
                continue
            }
            let computed = (try? SHA256.file(at: fileURL)) ?? ""
            guard computed == expected else {
                errors.append("checksum mismatch for \(relative)")
                continue
            }
        }
        guard errors.isEmpty else {
            throw ImportError.verificationFailed(errors)
        }
    }

    private func verifyHost(_ host: HostInfo.Info, against manifest: SDKManifest) throws {
        guard host.triple == manifest.hostTriple else {
            throw ImportError.hostTripleMismatch(host: host.triple, expected: manifest.hostTriple)
        }
        guard host.swiftMajor == manifest.swiftCompiler.major,
              host.swiftMinor == manifest.swiftCompiler.minor else {
            throw ImportError.swiftVersionMismatch(
                host: "\(host.swiftMajor).\(host.swiftMinor)",
                expected: "\(manifest.swiftCompiler.major).\(manifest.swiftCompiler.minor)"
            )
        }
    }
}

enum ImportError: Error, Equatable, Sendable, CustomStringConvertible {
    case archiveUnreadable(String)
    case checksumMismatch(computed: String, expected: String)
    case noArtifactBundle
    case multipleBundles([String])
    case missingManifest(String)
    case verificationFailed([String])
    case hostTripleMismatch(host: String, expected: String)
    case swiftVersionMismatch(host: String, expected: String)
    case installFailed(String)

    var description: String {
        switch self {
        case let .archiveUnreadable(path):
            return "Could not read SDK archive at '\(path)'."
        case let .checksumMismatch(computed, expected):
            return "Archive SHA-256 mismatch.\n  computed: \(computed)\n  expected: \(expected)"
        case .noArtifactBundle:
            return "The archive does not contain an `.artifactbundle` directory."
        case let .multipleBundles(names):
            return "The archive contains multiple artifact bundles: \(names.joined(separator: ", "))."
        case let .missingManifest(bundle):
            return "The bundle '\(bundle)' has no `sdk-manifest.json`; refusing to install."
        case let .verificationFailed(errors):
            return "SDK bundle verification failed:\n  " + errors.joined(separator: "\n  ")
        case let .hostTripleMismatch(host, expected):
            return "Host triple \(host) does not match the SDK bundle's \(expected)."
        case let .swiftVersionMismatch(host, expected):
            return "Host Swift \(host) does not match the SDK bundle's Swift \(expected)."
        case let .installFailed(bundle):
            return "`swift sdk install` failed for bundle '\(bundle)'. See stderr above."
        }
    }
}
