# stupid-app

A CLI for creating, building, signing, wirelessly deploying, and releasing iOS
applications without requiring Xcode or macOS at runtime.

Current status: **Gates 0 and 1 complete**. The device-only Swift SDK pipeline is
proven end-to-end on an isolated Ubuntu WSL host (export on macOS, validate and import
on Linux, cross-compile to an ARM64 Mach-O), and a real Apple Distribution-signed IPA
is produced on Linux with the pinned `rcodesign` signing kernel and verified
independently.

## Package layout

- `Sources/SDKCore` — cross-platform primitives: SHA-256 wrapper (`swift-crypto`),
  the SDK export manifest model, host triple / Swift version probing, and safe archive
  listing/validation.
- `Sources/ProjectCore` — the typed `stupid-app.yml` schema and project generator.
- `Sources/BuildCore` — SwiftPM planning, unsigned `.app` assembly, SDK-version
  discovery, and Mach-O inspection.
- `Sources/ASCKit` — App Store Connect ES256 JWT, HTTP client, and bundle-ID /
  certificate / profile operations; encrypted credential storage.
- `Sources/SigningKit` — provisioning-profile CMS parsing, entitlement derivation,
  the pinned `rcodesign` signing kernel adapter, and IPA packaging.
- `Sources/stupid-app` — the cross-platform CLI.
- `docs/rcodesign-pin.md` — the pinned signing kernel and its checksums.
- `docs/sdk-export-format.md` — the SDK bundle archive and manifest specification.
- `docs/engineering-handover.md` — the maintained engineering source of truth.
- `docs/implementation-notes.md` — the chronological engineering log.

## Commands

```text
stupid-app new <name>              Scaffold a SwiftPM/SwiftUI iOS project
stupid-app sdk export ...          (macOS) export a device-only Swift SDK bundle
stupid-app sdk import <archive>    (Linux) validate and install an SDK bundle
stupid-app build                   Build an unsigned iOS .app with the imported SDK
stupid-app credentials add         Store ASC API key + team ID (encrypted)
stupid-app signing setup --distribution   Provision a distribution identity + profile
stupid-app release archive         Build, sign (once, no timestamps), package the IPA
```

## Export (macOS)

```bash
swift run stupid-app sdk export \
  --xcode /Applications/Xcode.app \
  --host x86_64-unknown-linux-gnu \
  --target arm64-apple-ios \
  --output .
```

Produces `stupid-app-ios-arm64-apple-ios-x86_64-unknown-linux-gnu.artifactbundle.tar.zst`
and prints its SHA-256. The export is device-only (no simulator/macOS content) and pins
the Linux-hosted Darwin toolset (`ld64.lld`, `libtool`, `dsymutil`) by version and
checksum.

## Import (Linux)

```bash
swift build
.build/debug/stupid-app sdk import stupid-app-ios-arm64-apple-ios-x86_64-unknown-linux-gnu.artifactbundle.tar.zst \
  --expected-sha256 <sha256>
```

Verifies the archive checksum, rejects unsafe archive entries, verifies every declared
file checksum, checks host triple and Swift compiler compatibility, then registers the
bundle with `swift sdk install`.

## Cross-compile (Linux)

```bash
swift sdk list          # -> stupid-app-ios
swift build --swift-sdk stupid-app-ios
```

## Tests

```bash
swift test
```

## License and provenance

Adapts design concepts from xtool (MIT). The pinned `rcodesign` signing kernel is
MPL-2.0 (see `docs/rcodesign-pin.md`). See `docs/implementation-notes.md` for
provenance and the engineering handover for the current architecture and gates.