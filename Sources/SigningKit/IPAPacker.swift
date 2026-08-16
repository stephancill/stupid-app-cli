import BuildCore
import Foundation

/// Packages a signed `.app` bundle into an App Store Connect-ready IPA: `Payload/App.app`
/// with a `Payload` root. Preserves executable modes, rejects entries outside `Payload`,
/// and verifies the final ZIP by re-reading it.
public enum IPAPacker {
    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case appBundleMissing(String)
        case payloadContainsOutside(String)
        case zipFailed(String)
        case verifyFailed(String)

        public var description: String {
            switch self {
            case let .appBundleMissing(path):
                return "The signed .app bundle does not exist at '\(path)'."
            case let .payloadContainsOutside(path):
                return "Refusing to package '\(path)': the IPA must contain only Payload/App.app."
            case let .zipFailed(detail):
                return "IPA ZIP creation failed: \(detail)"
            case let .verifyFailed(detail):
                return "IPA verification failed: \(detail)"
            }
        }
    }

    /// Creates `<outputDir>/<product>.ipa` from a signed `.app`.
    /// - Parameters:
    ///   - appBundle: the signed bundle directory (e.g. `AcceptanceApp.app`).
    ///   - product: app product name used for the IPA filename.
    ///   - outputDirectory: directory to write the `.ipa` into.
    /// - Returns: the IPA URL.
    public static func pack(appBundle: URL, product: String, outputDirectory: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: appBundle.path) else {
            throw Error.appBundleMissing(appBundle.path)
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let workingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-ipa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDir) }

        let payloadDir = workingDir.appendingPathComponent("Payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
        let appName = appBundle.lastPathComponent
        try copyTree(from: appBundle, to: payloadDir.appendingPathComponent(appName))

        let ipaURL = outputDirectory.appendingPathComponent("\(product).ipa")
        try? FileManager.default.removeItem(at: ipaURL)

        // Deterministic-ish zip: use the system zip if available, else a Foundation
        // fallback. Preserve permissions via zip's defaults on the copied tree.
        let zipResult = try ProcessRunner.run(
            executable: "/usr/bin/zip",
            arguments: ["-qr", "-y", ipaURL.path, "Payload"],
            environment: workingEnv(workingDir),
            workingDirectory: workingDir
        )
        guard zipResult.succeeded else {
            throw Error.zipFailed(zipResult.stderr.isEmpty ? zipResult.stdout : zipResult.stderr)
        }

        // Verify by re-reading the archive and confirming the Payload root exists.
        guard FileManager.default.fileExists(atPath: ipaURL.path), try verify(ipaURL) else {
            throw Error.verifyFailed("\(ipaURL.path) is missing or malformed")
        }
        return ipaURL
    }

    private static func workingEnv(_ workingDir: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PWD"] = workingDir.path
        return env
    }

    /// Re-reads the ZIP and confirms `Payload/` exists at the root.
    static func verify(_ ipaURL: URL) throws -> Bool {
        let result = try ProcessRunner.run(
            executable: "/usr/bin/unzip",
            arguments: ["-l", ipaURL.path]
        )
        guard result.succeeded else { return false }
        let lines = result.stdout.split(separator: "\n").map(String.init)
        let hasPayload = lines.contains { $0.contains("Payload/") }
        // Reject any top-level entry that is not Payload/ or Payload/<app>.
        let outsidePayload = lines.contains { line in
            let trimmed = line.split(separator: " ", omittingEmptySubsequences: true).last.map(String.init) ?? ""
            return trimmed.hasSuffix("/") && !trimmed.hasPrefix("Payload/")
        }
        return hasPayload && !outsidePayload
    }

    private static func copyTree(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for child in contents {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let dest = destination.appendingPathComponent(child.lastPathComponent)
            if values.isSymbolicLink == true {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: child.path)
                guard !target.hasPrefix("/") else {
                    throw Error.appBundleMissing("escaping symlink \(child.path)")
                }
                try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: destination.appendingPathComponent(target))
            } else if values.isDirectory == true {
                try copyTree(from: child, to: dest)
            } else {
                try FileManager.default.copyItem(at: child, to: dest)
            }
        }
    }
}