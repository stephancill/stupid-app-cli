# SDK Export And Import Format

This document defines the versioned, checksummed, device-only Swift SDK bundle that the
exporter produces and the Linux importer consumes. It is part of the Gate 0 proof.

## Archive

The export is a single POSIX tar archive compressed with `zstd`:

```
stupid-app-ios-<target-triple>-<host-triple>.artifactbundle.tar.zst
```

The archive contains exactly one SwiftPM artifact bundle directory named
`stupid-app-ios-<target-triple>-<host-triple>.artifactbundle/`. SwiftPM owns the
installation layout, so the importer registers the validated bundle with
`swift sdk install` rather than inventing its own registry.

Example:

```
stupid-app-ios-arm64-apple-ios-x86_64-unknown-linux-gnu.artifactbundle/
  info.json                 # SwiftPM artifact bundle manifest (schema 1.0)
  swift-sdk.json            # target triple configuration (schema 4.0)
  toolset.json              # linker/compiler toolset configuration
  sdk-manifest.json         # stupid-app export manifest (this document's schema)
  Developer/
    Platforms/iPhoneOS.platform/Developer/
      SDKs/iPhoneOS.sdk/          # the device-only iPhoneOS SDK
      usr/lib/                    # platform library search paths
    Toolchains/XcodeDefault.xctoolchain/usr/lib/
      swift/iphoneos/             # device Swift runtime resources and modules
      swift/clang                 # symlink -> ../clang/<major>
      swift/apinotes/
      swift/_InternalSwiftScan/
      clang/                      # clang resource directory for the device target
  toolset/
    bin/
      ld64.lld
      libtool
      dsymutil
```

## `info.json`

The standard SwiftPM artifact bundle manifest. Schema version `1.0`. The artifact ID
(here `stupid-app-ios`) is the selector passed to `swift build --swift-sdk`.

```json
{
  "schemaVersion": "1.0",
  "artifacts": {
    "stupid-app-ios": {
      "type": "swiftSDK",
      "version": "<iphoneos-sdk-version>",
      "variants": [
        {
          "path": ".",
          "supportedTriples": ["<host-triple>"]
        }
      ]
    }
  }
}
```

## `swift-sdk.json`

Schema version `4.0`. The bundle supports exactly one target triple: `arm64-apple-ios`.
All paths are relative to the artifact bundle root.

```json
{
  "schemaVersion": "4.0",
  "targetTriples": {
    "arm64-apple-ios": {
      "sdkRootPath": "Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk",
      "includeSearchPaths": ["Developer/Platforms/iPhoneOS.platform/Developer/usr/lib"],
      "librarySearchPaths": ["Developer/Platforms/iPhoneOS.platform/Developer/usr/lib"],
      "swiftResourcesPath": "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift",
      "toolsetPaths": ["toolset.json"]
    }
  }
}
```

`swiftStaticResourcesPath` is omitted because the device Swift runtime is provided by the
OS; the toolchain in scope has no `swift_static/iphoneos` content.

## `toolset.json`

Schema version `1.0`. The linker and host-side compiler flags. `rootPath` is relative to
the artifact bundle root.

```json
{
  "schemaVersion": "1.0",
  "rootPath": "toolset/bin",
  "linker": {
    "path": "ld64.lld"
  },
  "swiftCompiler": {
    "extraCLIOptions": [
      "-Xfrontend", "-enable-cross-import-overlays",
      "-use-ld=lld"
    ]
  }
}
```

## `sdk-manifest.json`

The `stupid-app` export manifest. It records generator provenance, the validated source
Xcode/SDK/Swift versions, the host and target triples, and a canonical SHA-256 for every
file in the bundle.

```json
{
  "formatVersion": 1,
  "generator": "stupid-app",
  "generatorVersion": "0.1.0",
  "sourceXcode": {
    "version": "26.1.1",
    "build": "17B100"
  },
  "iphoneosSDKVersion": "26.2",
  "swiftCompiler": {
    "version": "6.2.1",
    "major": 6,
    "minor": 2
  },
  "hostTriple": "x86_64-unknown-linux-gnu",
  "targetTriple": "arm64-apple-ios",
  "darwinTools": {
    "source": "https://github.com/xtool-org/darwin-tools-linux-llvm/releases/download/v1.0.1/toolset-x86_64.tar.gz",
    "version": "1.0.1",
    "sha256": "<toolset-archive-sha256>"
  },
  "files": {
    "info.json": "<sha256>",
    "swift-sdk.json": "<sha256>",
    "toolset.json": "<sha256>",
    "Developer/...": "<sha256>",
    "toolset/bin/ld64.lld": "<sha256>",
    "...": "..."
  }
}
```

- `files` keys are paths relative to the artifact bundle root, using `/` separators.
  Symlinks are not hashed; their resolved contents are recorded under the canonical name
  the symlink points to.
- `swiftCompiler` is the Swift version of the toolchain that produced the SDK resources
  (`XcodeDefault.xctoolchain`). The importer rejects a host Swift compiler whose major/minor
  pair does not match this value, because the prebuilt modules and resource directory are
  compiler-version-specific.

For a macOS Mode B host (`sdk export --host arm64-apple-macosx`) the `darwinTools`
record is provenance only: `source` is the pinned Homebrew keg set (e.g.
`homebrew:lld@20,llvm@20,zstd`), `version` is the LLVM version, and `sha256` is the
checksum of the bundled `toolset/bin/ld64.lld`. Integrity is enforced by the per-file
checksums in `files` (which cover the relocated binaries and dylibs under `toolset/bin`
and `toolset/lib`). See `docs/mode-b-darwin-tools.md` and
`docs/macos-host-support-scope.md`.

## Compatibility

The exporter must reject:

- A host triple whose architecture is not present in the pinned Darwin tools for that
  host (Linux `x86_64`/`aarch64` archives, or the macOS `arm64` Homebrew toolset under
  `*-apple-macosx`; Intel macOS is deferred).
- Multiple numeric iPhoneOS SDK versions in the Xcode installation.
- A missing or unreadable Xcode `Contents/Developer` directory.
- Unsupported paths that would require a resource compiler not present on Linux
  (e.g. simulator platforms).

## Import Requirements

The importer (`stupid-app sdk import`) must:

1. Verify the archive SHA-256 against the value recorded at export time.
2. Extract to a temporary sibling directory using a safe archive reader that rejects
   absolute paths, path traversal, and symlinks escaping the installation root.
3. Verify `sdk-manifest.json` exists and every declared file's SHA-256 matches.
4. Reject a host triple or architecture mismatch.
5. Reject an unsupported host Swift/SDK compiler pairing.
6. Register the validated bundle with `swift sdk install` after the above passes.
7. Keep the prior working SDK until the replacement passes a smoke compilation.
8. Allow multiple versioned SDKs to coexist.
