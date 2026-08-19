import Testing
@testable import SDKCore

/// Unit tests for the pinned macOS-hosted Mode B Darwin toolset metadata.
struct DarwinToolsTests {
  @Test("recognizes macOS host triples")
  func macHostDetection() {
    #expect(DarwinTools.isMacOSHost("arm64-apple-macosx"))
    #expect(DarwinTools.isMacOSHost("x86_64-apple-macosx"))
    #expect(DarwinTools.isMacOSHost("arm64-apple-macos"))
    #expect(DarwinTools.isMacOSHost("x86_64-unknown-linux-gnu") == false)
    #expect(DarwinTools.isMacOSHost("arm64-apple-ios") == false)
  }

  @Test("resolves the pinned arm64 macOS toolset")
  func arm64Toolset() {
    #expect(DarwinTools.macOSHosted(forHostTriple: "arm64-apple-macosx")?.arch == "arm64")
    #expect(DarwinTools.macOSHosted(forHostTriple: "arm64-apple-macosx")?.version == "20.1.8")
  }

  @Test("deferring Intel returns no toolset")
  func intelToolsetDeferred() {
    #expect(DarwinTools.macOSHosted(forHostTriple: "x86_64-apple-macosx") == nil)
  }

  @Test("resolves the pinned aarch64 Linux darwin-toolset")
  func aarch64LinuxToolset() {
    let src = DarwinTools.source(for: "aarch64")
    #expect(src?.arch == "aarch64")
    #expect(src?.version == "1.0.1")
    #expect(src?.sha256 == "2660178e19983ab23bbeaea5f2ff2fefbe516302936a066ccd2370f36e019bbe")
    #expect(src?.url.lastPathComponent == "toolset-aarch64.tar.gz")
  }

  @Test("macOS toolset carries the three Darwin tools")
  func macToolsBinaries() {
    let names = DarwinTools.macOSHostedArm64.binaries.map(\.bundleName)
    #expect(Set(names) == ["ld64.lld", "libtool", "dsymutil"])
  }

  @Test("macOS toolset carries the LLVM/lld/zstd dylibs under toolset/lib")
  func macToolsDylibs() {
    let names = DarwinTools.macOSHostedArm64.dylibs.map(\.bundleName)
    #expect(names.contains("libLLVM.dylib"))
    #expect(names.contains("liblldMachO.dylib"))
    #expect(names.contains("libzstd.1.dylib"))
    #expect(names.contains("liblldELF.dylib"))
  }
}
