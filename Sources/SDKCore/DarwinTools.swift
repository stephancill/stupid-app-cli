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

    /// Describes a macOS-hosted Mode B tool relevant to `sdk export --host <mac-triple>`.
    public struct MacOSBinary: Equatable, Sendable {
        /// Which keg the source lives in (`lld` or `llvm`).
        public var keg: String
        /// Bundle filename under `toolset/bin`.
        public var bundleName: String
        /// Source filename in the keg's `bin` directory.
        public var source: String
    }

    public struct MacOSDylib: Equatable, Sendable {
        /// Which keg the source lives in (`lld`, `llvm`, or `zstd`).
        public var keg: String
        /// Bundle filename under `toolset/lib`.
        public var bundleName: String
        /// Source filename in the keg's `lib` directory.
        public var source: String
        /// Optional `-id` install name applied at relocation time.
        public var installName: String?
    }

    /// A pinned macOS-hosted Darwin toolset sourced from Homebrew's `lld`/`llvm`/`zstd`
    /// kegs. Only `arm64-apple-macosx` is supported (decision 8); Intel is deferred.
    public struct MacOSHosted: Equatable, Sendable {
        public var arch: String
        /// LLVM version of the pinned kegs (e.g. "20.1.8").
        public var version: String
        public var lldBinDir: String
        public var llvmBinDir: String
        public var lldLibDir: String
        public var llvmLibDir: String
        public var zstdLibDir: String
        public var binaries: [MacOSBinary]
        public var dylibs: [MacOSDylib]
        /// Absolute Homebrew load paths rewritten to `@rpath/<name>` during relocation.
        public var llvmLoadPath: String
        public var zstdLoadPath: String

        public init(
            arch: String,
            version: String,
            lldBinDir: String,
            llvmBinDir: String,
            lldLibDir: String,
            llvmLibDir: String,
            zstdLibDir: String,
            binaries: [MacOSBinary],
            dylibs: [MacOSDylib],
            llvmLoadPath: String,
            zstdLoadPath: String
        ) {
            self.arch = arch
            self.version = version
            self.lldBinDir = lldBinDir
            self.llvmBinDir = llvmBinDir
            self.lldLibDir = lldLibDir
            self.llvmLibDir = llvmLibDir
            self.zstdLibDir = zstdLibDir
            self.binaries = binaries
            self.dylibs = dylibs
            self.llvmLoadPath = llvmLoadPath
            self.zstdLoadPath = zstdLoadPath
        }
    }

    /// The pinned macOS-hosted toolset (ARM64, Homebrew prefix `/opt/homebrew`).
    public static let macOSHostedArm64: MacOSHosted = {
        let prefix = "/opt/homebrew"
        let llvmLib = "\(prefix)/opt/llvm@20/lib"
        let lldLib = "\(prefix)/opt/lld@20/lib"
        return MacOSHosted(
            arch: "arm64",
            version: "20.1.8",
            lldBinDir: "\(prefix)/opt/lld@20/bin",
            llvmBinDir: "\(prefix)/opt/llvm@20/bin",
            lldLibDir: lldLib,
            llvmLibDir: llvmLib,
            zstdLibDir: "\(prefix)/opt/zstd/lib",
            binaries: [
                MacOSBinary(keg: "lld", bundleName: "ld64.lld", source: "lld"),
                MacOSBinary(keg: "llvm", bundleName: "libtool", source: "llvm-libtool-darwin"),
                MacOSBinary(keg: "llvm", bundleName: "dsymutil", source: "dsymutil"),
            ],
            dylibs: [
                MacOSDylib(keg: "lld", bundleName: "liblldMachO.dylib", source: "liblldMachO.dylib", installName: "@rpath/liblldMachO.dylib"),
                MacOSDylib(keg: "lld", bundleName: "liblldCommon.dylib", source: "liblldCommon.dylib", installName: "@rpath/liblldCommon.dylib"),
                MacOSDylib(keg: "lld", bundleName: "liblldELF.dylib", source: "liblldELF.dylib", installName: "@rpath/liblldELF.dylib"),
                MacOSDylib(keg: "lld", bundleName: "liblldCOFF.dylib", source: "liblldCOFF.dylib", installName: "@rpath/liblldCOFF.dylib"),
                MacOSDylib(keg: "lld", bundleName: "liblldWasm.dylib", source: "liblldWasm.dylib", installName: "@rpath/liblldWasm.dylib"),
                MacOSDylib(keg: "lld", bundleName: "liblldMinGW.dylib", source: "liblldMinGW.dylib", installName: "@rpath/liblldMinGW.dylib"),
                MacOSDylib(keg: "llvm", bundleName: "libLLVM.dylib", source: "libLLVM.dylib", installName: "@rpath/libLLVM.dylib"),
                MacOSDylib(keg: "zstd", bundleName: "libzstd.1.dylib", source: "libzstd.1.5.7.dylib", installName: "@rpath/libzstd.1.dylib"),
            ],
            llvmLoadPath: "\(llvmLib)/libLLVM.dylib",
            zstdLoadPath: "\(prefix)/opt/zstd/lib/libzstd.1.dylib"
        )
    }()

    /// True when the host triple targets macOS (Mode B exporter path).
    public static func isMacOSHost(_ triple: String) -> Bool {
        triple.contains("apple-macosx") || triple.contains("apple-macos")
    }

    /// Returns the pinned macOS-hosted toolset for a host triple's architecture, or nil
    /// for an unsupported host (e.g. Intel `x86_64-apple-macosx`).
    public static func macOSHosted(forHostTriple triple: String) -> MacOSHosted? {
        let tripleArch = triple.split(separator: "-").first.map(String.init) ?? ""
        if tripleArch.hasPrefix("arm64") || tripleArch == "aarch64" {
            return macOSHostedArm64
        }
        return nil
    }
}
