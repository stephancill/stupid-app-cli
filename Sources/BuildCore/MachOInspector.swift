import Foundation

/// Minimal Mach-O inspection used to validate assembled executables without Apple
/// tooling: confirms the file is an ARM64 Mach-O (not ELF) and reads the
/// `LC_BUILD_VERSION` platform, minimum OS, and SDK version.
public enum MachOInspector {
    public struct Info: Equatable, Sendable {
        public var isMachO: Bool
        public var cpuArchitecture: String?
        public var platform: String?
        public var minimumOS: String?
        public var sdkVersion: String?

        public static let none = Info(isMachO: false, cpuArchitecture: nil, platform: nil, minimumOS: nil, sdkVersion: nil)
    }

    // Mach-O constants. Thin-file magic is stored in the native byte order of the
    // producing architecture; we read with `loadUnaligned` (native endianness), so we
    // compare against the plain constants, not `.bigEndian`-wrapped values.
    private static let fat64Magic = UInt32(0xCafebabf)
    private static let fatMagic = UInt32(0xCafebabe)
    private static let thinMagic64 = UInt32(0xfeedfacf)
    private static let thinMagic32 = UInt32(0xfeedface)
    private static let cputypeARM64 = Int32(0x0100000C) // CPU_TYPE_ARM64
    private static let lcBuildVersion: UInt32 = 0x32

    public static func inspect(data: Data) -> Info {
        guard data.count >= 4 else { return .none }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }

        switch magic {
        case fat64Magic, fatMagic:
            // Fat binaries: inspect the first slice architecture. Version 1 only
            // produces thin ARM64 binaries, so this is informational.
            return Info(isMachO: true, cpuArchitecture: nil, platform: nil, minimumOS: nil, sdkVersion: nil)
        case thinMagic64:
            return parseThin(data: data, is64Bit: true)
        case thinMagic32:
            return parseThin(data: data, is64Bit: false)
        default:
            return .none
        }
    }

    public static func inspect(at url: URL) throws -> Info {
        guard let data = try? Data(contentsOf: url) else {
            throw BuildError.processingFailed("Mach-O inspection", "Could not read \(url.path).")
        }
        return inspect(data: data)
    }

    /// A convenience `@Sendable` wrapper for concurrent verification.
    public static func inspectConcurrently(at url: URL) throws -> Info {
        try inspect(at: url)
    }

    private static func parseThin(data: Data, is64Bit: Bool) -> Info {
        let headerSize = is64Bit ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size
        guard data.count >= headerSize else { return .none }

        let cputype: Int32
        let ncmds: UInt32
        let sizeofcmds: UInt32
        if is64Bit {
            let header = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: mach_header_64.self) }
            cputype = header.cputype
            ncmds = header.ncmds
            sizeofcmds = header.sizeofcmds
        } else {
            let header = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: mach_header.self) }
            cputype = header.cputype
            ncmds = header.ncmds
            sizeofcmds = header.sizeofcmds
        }

        let architecture = cputype == cputypeARM64 ? "arm64" : nil
        var platform: String?
        var minimumOS: String?
        var sdkVersion: String?

        // Walk load commands looking for LC_BUILD_VERSION.
        var offset = headerSize
        for _ in 0..<ncmds {
            guard offset + 8 <= data.count else { break }
            let cmd = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: load_command.self) }
            defer {
                offset += Int(cmd.cmdsize)
            }
            if cmd.cmd == lcBuildVersion, offset + 24 <= data.count {
                let build = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: build_version_command.self) }
                platform = Self.platformName(build.platform)
                minimumOS = Self.versionString(build.minos)
                sdkVersion = Self.versionString(build.sdk)
            }
            if sizeofcmds > 0, offset >= headerSize + Int(sizeofcmds) {
                break
            }
        }

        return Info(
            isMachO: true,
            cpuArchitecture: architecture,
            platform: platform,
            minimumOS: minimumOS,
            sdkVersion: sdkVersion
        )
    }

    private static func platformName(_ platform: UInt32) -> String? {
        switch platform {
        case 2: return "ios"
        case 1: return "macos"
        case 7: return "ios-simulator"
        default: return "unknown"
        }
    }

    private static func versionString(_ raw: UInt32) -> String {
        let major = (raw >> 16) & 0xFFFF
        let minor = (raw >> 8) & 0xFF
        let patch = raw & 0xFF
        return "\(major).\(minor).\(patch)"
    }
}

// Replicated Mach-O struct layouts for Linux portability (no Darwin headers).
private struct mach_header {
    let magic: UInt32
    let cputype: Int32
    let cpusubtype: Int32
    let filetype: UInt32
    let ncmds: UInt32
    let sizeofcmds: UInt32
    let flags: UInt32
}

private struct mach_header_64 {
    let magic: UInt32
    let cputype: Int32
    let cpusubtype: Int32
    let filetype: UInt32
    let ncmds: UInt32
    let sizeofcmds: UInt32
    let flags: UInt32
    let reserved: UInt32
}

private struct load_command {
    let cmd: UInt32
    let cmdsize: UInt32
}

private struct build_version_command {
    let cmd: UInt32
    let cmdsize: UInt32
    let platform: UInt32
    let minos: UInt32
    let sdk: UInt32
    let ntools: UInt32
}