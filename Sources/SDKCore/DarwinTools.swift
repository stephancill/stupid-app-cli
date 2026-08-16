import Foundation

/// Pinned Linux-hosted Darwin toolchain sources.
///
/// These tools (`ld64.lld`, `libtool`, `dsymutil`) run on the Linux host and perform the
/// Mach-O linking/processing that Apple tooling normally provides. The revision and
/// checksum below are pinned; the exporter downloads and verifies the archive before use.
/// Do not fetch unpinned or unverified toolset bytes.
public enum DarwinTools {
    public struct Source: Equatable, Sendable {
        public var arch: String
        public var url: URL
        public var version: String
        public var sha256: String

        public init(arch: String, url: URL, version: String, sha256: String) {
            self.arch = arch
            self.url = url
            self.version = version
            self.sha256 = sha256
        }
    }

    /// Pinned v1.0.1 release of `xtool-org/darwin-tools-linux-llvm`.
    public static let pinned: [Source] = [
        Source(
            arch: "x86_64",
            url: URL(
                string: "https://github.com/xtool-org/darwin-tools-linux-llvm/releases/download/v1.0.1/toolset-x86_64.tar.gz"
            )!,
            version: "1.0.1",
            sha256: "58f567cbea08afb89aaee5ca0c2200e6c9fe7c014022fe380f0188e940d8d071"
        ),
    ]

    public static func source(for hostArch: String) -> Source? {
        pinned.first { $0.arch == hostArch }
    }

    /// Expected tool binaries inside the extracted toolset archive.
    public static let binaries = ["ld64.lld", "libtool", "dsymutil"]
}
