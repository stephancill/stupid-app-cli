import Crypto
import Foundation

/// Thin wrapper around `swift-crypto`'s audited `SHA256` implementation.
///
/// The `Crypto` product of the `swift-crypto` package is cross-platform (macOS and
/// Linux) and is already a candidate dependency in the engineering handover. Keeping a
/// wrapper here gives the rest of the codebase one call site and a stable API, and lets
/// tests exercise the exact hashing path used by the exporter and importer.
public enum SHA256 {
    /// Lowercase hex SHA-256 of the given data.
    public static func hex(data: Data) -> String {
        Crypto.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase hex SHA-256 of a file's contents, streamed in chunks to bound memory.
    public static func file(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = Crypto.SHA256()
        let chunk = 1 << 20
        while let data = try handle.read(upToCount: chunk), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
