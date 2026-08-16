# iosdev

A CLI for creating, building, signing, wirelessly deploying, and releasing iOS
applications without requiring Xcode or macOS at runtime.

Current status: **Gate 0 complete**. The device-only Swift SDK pipeline is proven
end-to-end on an isolated Ubuntu WSL host — export on macOS, validate and import on
Linux, and cross-compile and link a minimal SwiftUI app to an ARM64 Mach-O.

## Package layout

- `Sources/SDKCore` — cross-platform primitives: SHA-256 wrapper (`swift-crypto`),
  the SDK export manifest model, host triple / Swift version probing, and safe archive
  listing/validation.
- `Sources/iosdev-sdk-export` — macOS-only exporter. Produces a device-only, checksummed
  iPhoneOS Swift SDK bundle from an installed Xcode.
- `Sources/iosdev` — cross-platform CLI. Currently implements `sdk import`.
- `docs/sdk-export-format.md` — the SDK bundle archive and manifest specification.
- `docs/engineering-handover.md` — the maintained engineering source of truth.
- `docs/implementation-notes.md` — the chronological engineering log.

## Export (macOS)

```bash
swift run iosdev-sdk-export \
  --xcode /Applications/Xcode.app \
  --host x86_64-unknown-linux-gnu \
  --target arm64-apple-ios \
  --output .
```

Produces `ios-dev-arm64-apple-ios-x86_64-unknown-linux-gnu.artifactbundle.tar.zst` and
prints its SHA-256. The export is device-only (no simulator/macOS content) and pins the
Linux-hosted Darwin toolset (`ld64.lld`, `libtool`, `dsymutil`) by version and checksum.

## Import (Linux)

```bash
swift build
.build/debug/iosdev sdk import ios-dev-arm64-apple-ios-x86_64-unknown-linux-gnu.artifactbundle.tar.zst \
  --expected-sha256 <sha256>
```

Verifies the archive checksum, rejects unsafe archive entries, verifies every declared
file checksum, checks host triple and Swift compiler compatibility, then registers the
bundle with `swift sdk install`.

## Cross-compile (Linux)

```bash
swift sdk list          # -> ios-dev
swift build --swift-sdk ios-dev
```

Note: Linux clang defaults the SDK version in `LC_BUILD_VERSION` to the deployment
target. Pass explicit `-platform_version` linker flags (as the future planner will) to
record the real SDK version.

## Tests

```bash
swift test
```

## License and provenance

Adapts design concepts from xtool (MIT). See `docs/implementation-notes.md` for
provenance and the engineering handover for the current architecture and gates.
