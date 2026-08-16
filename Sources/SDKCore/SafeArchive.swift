import Foundation

/// Safe extraction of the SDK archive on the Linux importer.
///
/// `bsdtar` on macOS and GNU `tar` on Linux both support `--zstd`; the archive format is
/// `tar.zst`. This module shells out to the platform `tar` after validating the archive
/// with our own list-and-verify step so that malicious archives never reach extraction.
public enum SafeArchive {
    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case tarUnavailable
        case archiveNotReadable
        case unsafeEntry(String)
        case archiveListingFailed(String)
        case extractionFailed(String)

        public var description: String {
            switch self {
            case .tarUnavailable:
                return "The 'tar' tool was not found; it is required to unpack the SDK archive."
            case .archiveNotReadable:
                return "The SDK archive could not be read."
            case let .unsafeEntry(entry):
                return "SDK archive contains an unsafe entry: '\(entry)'. Rejecting archive."
            case let .archiveListingFailed(output):
                return "Could not list the SDK archive contents. \(output)"
            case let .extractionFailed(output):
                return "Could not extract the SDK archive. \(output)"
            }
        }
    }

    /// Lists archive entries by invoking `tar --list` on the platform tool.
    ///
    /// Returns the raw entries, one per line, with trailing slashes for directories.
    public static func listEntries(at archive: URL) async throws -> [String] {
        guard let tar = locateTar() else { throw Error.tarUnavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tar)
        process.arguments = ["-tf", archive.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // Drain both pipes before waiting to avoid pipe-buffer deadlock when the archive
        // contains many entries or warnings.
        let outTask = Task.detached { () -> Data in
            stdout.fileHandleForReading.readDataToEndOfFile()
        }
        let errTask = Task.detached { () -> Data in
            stderr.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()
        let outData = try await outTask.value
        let errData = try await errTask.value
        guard process.terminationStatus == 0 else {
            throw Error.archiveListingFailed(String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: outData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// Validates that every entry is a safe relative path. Rejects absolute paths, path
    /// traversal, AppleDouble metadata, and entries that escape the extraction root.
    public static func validateEntries(_ entries: [String]) throws {
        for raw in entries {
            // A trailing slash marks a directory entry; drop it for path validation.
            let entry = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            guard !entry.isEmpty else { continue }

            guard !entry.hasPrefix("/") else { throw Error.unsafeEntry(raw) }

            let components = entry.split(separator: "/").map(String.init)
            guard let first = components.first else { continue }
            // Reject AppleDouble `._*` metadata entries produced by macOS tools.
            if first.hasPrefix("._") {
                throw Error.unsafeEntry(raw)
            }
            // Reject a leading "." that would alias the root, drive letters, or traversal.
            if first == "." || first == ".." || first.hasSuffix(":") {
                throw Error.unsafeEntry(raw)
            }
            // Reject traversal anywhere in the path.
            for component in components.dropFirst() where component == ".." {
                throw Error.unsafeEntry(raw)
            }
        }
    }

    /// Extracts the archive into `destination` (which must already exist) after validation.
    public static func extract(archive: URL, to destination: URL) async throws {
        let entries = try await listEntries(at: archive)
        try validateEntries(entries)
        guard let tar = locateTar() else { throw Error.tarUnavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tar)
        process.currentDirectoryURL = destination
        process.arguments = ["-xf", archive.path, "-C", destination.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        let errTask = Task.detached { () -> Data in
            stderr.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()
        let errData = try await errTask.value
        guard process.terminationStatus == 0 else {
            throw Error.extractionFailed(String(decoding: errData, as: UTF8.self))
        }
    }

    /// Locates a `tar` binary on PATH.
    public static func locateTar() -> String? {
        let searchPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        for dir in searchPaths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("tar").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
