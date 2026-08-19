import BuildCore
import Foundation
import Testing

/// Hermetic Mach-O inspection tests. Builds a synthetic thin ARM64 `MH_EXECUTE` with an
/// `LC_BUILD_VERSION` load command and verifies `MachOInspector` reads the architecture,
/// platform, minimum OS, and SDK version without any Apple tooling.
struct MachOInspectorTests {
    private static let magicRuntime = UInt32(0xfeedfacf)  // MH_MAGIC_64
    private static let cputypeARM64 = Int32(0x0100_000C)  // CPU_TYPE_ARM64
    private static let filetypeExecute = UInt32(2)        // MH_EXECUTE
    private static let lcBuildVersion = UInt32(0x32)
    private static let platformIOS = UInt32(2)

    private static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private static func le32(_ value: Int32) -> [UInt8] {
        le32(UInt32(bitPattern: value))
    }

    private static func version(_ major: UInt16, _ minor: UInt16, _ patch: UInt16) -> UInt32 {
        (UInt32(major) << 16) | (UInt32(minor) << 8) | UInt32(patch)
    }

    private static func thinArm64MachO(minOS: UInt32 = version(17, 0, 0), sdk: UInt32 = version(26, 1, 0)) -> Data {
        // mach_header_64 (32 bytes) followed by one LC_BUILD_VERSION (24 bytes).
        var bytes: [UInt8] = []
        bytes += le32(magicRuntime)
        bytes += le32(cputypeARM64)
        bytes += le32(UInt32(0))   // cpusubtype
        bytes += le32(filetypeExecute)
        bytes += le32(UInt32(1))   // ncmds
        bytes += le32(UInt32(24))  // sizeofcmds
        bytes += le32(UInt32(0))   // flags
        bytes += le32(UInt32(0))   // reserved
        bytes += le32(lcBuildVersion)
        bytes += le32(UInt32(24))  // cmdsize
        bytes += le32(platformIOS)
        bytes += le32(minOS)
        bytes += le32(sdk)
        bytes += le32(UInt32(0))   // ntools
        return Data(bytes)
    }

    @Test("parses architecture, platform, minos, and sdk from a synthetic ARM64 Mach-O")
    func parsesSyntheticMachO() {
        let info = MachOInspector.inspect(data: Self.thinArm64MachO())
        #expect(info.isMachO)
        #expect(info.cpuArchitecture == "arm64")
        #expect(info.platform == "ios")
        #expect(info.minimumOS == "17.0.0")
        #expect(info.sdkVersion == "26.1.0")
    }

    @Test("reports none for an ELF executable")
    func rejectsELF() {
        // ELF magic 0x464C457F ("\x7FELF").
        var bytes: [UInt8] = [0x7F, 0x45, 0x4C, 0x46]
        bytes += [UInt8](repeating: 0, count: 12)
        let info = MachOInspector.inspect(data: Data(bytes))
        #expect(!info.isMachO)
        #expect(info.cpuArchitecture == nil)
    }

    @Test("reports none for a too-short payload")
    func rejectsShortPayload() {
        #expect(!MachOInspector.inspect(data: Data([0x00, 0x01])).isMachO)
    }

    @Test("does not identify a non-ARM64 CPU architecture")
    func nonARM64Architecture() {
        // Patch the cputype to x86_64 before calling inspect.
        let original = Self.thinArm64MachO()
        var data = original
        let cputypeRange = 4..<8
        data.replaceSubrange(cputypeRange, with: Data(Self.le32(Int32(0x0100_0007))))  // CPU_TYPE_X86_64
        let info = MachOInspector.inspect(data: data)
        #expect(info.isMachO)
        #expect(info.cpuArchitecture == nil)
    }
}
