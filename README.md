# stupid-app

A CLI for creating, building, signing, wirelessly deploying, and releasing iOS
applications without requiring Xcode or macOS at runtime.

Current status: **Gates 0 through 4 complete; Gate 5 productization remains**. The
device-only Swift SDK pipeline is proven end-to-end on an isolated Ubuntu WSL host
(export on macOS, validate and import on Linux, cross-compile to an ARM64 Mach-O), and
a real Apple Distribution-signed IPA is produced on Linux with the pinned `rcodesign`
signing kernel and verified independently. The App Store Connect Build Upload client
(`stupid-app release upload --wait`) uploaded a Linux-built IPA that processed as
`VALID`, became internally TestFlight-ready, installed through TestFlight, and launched.
The accepted app icon uses the native `Assets.car` writer with Apple's pinned LZFSE
reference encoder and `actool`-matching icon metadata.
Development signing, USB installation, CoreDevice pairing, and three consecutive
unplugged network install-and-launch runs are also proven on a physical iPhone.

## Package layout

- `Sources/SDKCore` — cross-platform primitives: SHA-256 wrapper (`swift-crypto`),
  the SDK export manifest model, host triple / Swift version probing, and safe archive
  listing/validation.
- `Sources/ProjectCore` — the typed `stupid-app.yml` schema and project generator.
- `Sources/BuildCore` — SwiftPM planning, unsigned `.app` assembly, SDK-version
  discovery, native app-icon generation and `Assets.car` writing (`swift-png`), and
  Mach-O inspection.
- `Sources/CLZFSE` — Apple's pinned BSD-3-Clause LZFSE reference implementation used
  for compressed native asset-catalog payloads.
- `Sources/ASCKit` — App Store Connect ES256 JWT, HTTP client, and bundle-ID /
  certificate / profile / Build Upload operations; permission-hardened credential
  storage; the release manifest.
- `Sources/SigningKit` — provisioning-profile CMS parsing, entitlement derivation,
  the pinned `rcodesign` signing kernel adapter, and IPA packaging.
- `Sources/DeviceKit` — bounded USB installation plus CoreDevice pairing, tunnel,
  network installation, and launch integration.
- `Tools/pymobiledevice3` — the frozen Python 3.13 / pymobiledevice3 8.2.1 environment.
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
stupid-app credentials add         Store ASC API key + team ID (0600 files)
stupid-app signing setup --kind distribution   Provision a distribution identity + profile
stupid-app signing setup --kind development    Provision a development identity + profile
stupid-app devices                  List App Store Connect devices
stupid-app device pair --usb        Bootstrap CoreDevice remote pairing over USB
stupid-app run --usb                Build, sign, install, and launch over USB
stupid-app run --network --udid ... Build, sign, install, and launch over the network
stupid-app release archive         Build, sign (once, no timestamps), package the IPA
stupid-app release upload --wait   Upload the IPA and wait for internal TestFlight
```

CoreDevice tunneling requires `/dev/net/tun` and `CAP_NET_ADMIN`. The CLI never
elevates implicitly: run an already-privileged helper or pass an explicit `--sudo`
path. Production setup should install the helper root-owned and grant only that exact
Python/helper command in sudoers. Pairing records are stored under the permission-
hardened credential directory.

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
MPL-2.0 (see `docs/rcodesign-pin.md`), and the vendored LZFSE encoder is BSD-3-Clause
(see `THIRD_PARTY_NOTICES.md`). See `docs/implementation-notes.md` for provenance and
the engineering handover for the current architecture and gates.
