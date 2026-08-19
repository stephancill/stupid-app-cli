# stupid-app

A CLI for creating, building, signing, wirelessly deploying, and releasing iOS
applications without requiring Xcode or macOS at runtime.

Current status: **Gates 0 through 4 complete; Gate 5 productization remains**. The
device-only Swift SDK pipeline is proven end-to-end on an isolated Ubuntu WSL host
(export on macOS, validate and import on Linux, cross-compile to an ARM64 Mach-O), and
a real Apple Distribution-signed IPA is produced on Linux with the project-owned native
Swift signer and verified independently. The App Store Connect Build Upload client
(`stupid-app release upload --wait`) uploaded a Linux-built IPA that processed as
`VALID`, became internally TestFlight-ready, installed through TestFlight, and launched.
The accepted app icon uses the native `Assets.car` writer with Apple's pinned LZFSE
reference encoder and `actool`-matching icon metadata.
Development signing, USB installation, CoreDevice pairing, and three consecutive
unplugged network install-and-launch runs are proven on a physical iPhone. The native
`device pair --usb`, native USB launch, and the fully native `run --network` path are
qualified end-to-end without Python; see `docs/implementation-notes.md` for the
investigation that resolved the network-run relay defect.

macOS host support is implemented through Gate M3: the Xcode-present build path, the
`simctl` simulator run loop (`stupid-app run --simulator`), a macOS-produced distribution
release qualified through TestFlight, and Xcode-present physical-device deployment. A
single `stupid-app signing setup` command bootstraps all signing credentials from one App
Store Connect API key and can reuse the identities and provisioning profiles Xcode already
manages on macOS (`--from-xcode`).

## Supported platforms

- **Production Linux host (v1):** x86_64 Ubuntu 24.04 LTS. This is the officially
  supported non-macOS deployment host.
- **Reference Linux environment:** the isolated `iosdev-ubuntu` WSL 2 distribution is a
  proof/reference environment, not a supported production target. The `usbipd-win` USB
  pass-through and the qualified MTU-patched `usbmuxd` are specific to that WSL setup and
  are documented only for reproduction (see `docs/clean-host-setup.md`).
- **macOS (additive):** Apple Silicon macOS 14+, in either Xcode-present (in-place SDK)
  or Xcode-absent (imported bundle) mode. See `docs/macos-host-support-scope.md`.

## Version 1 entitlement scope

Version 1 officially supports the bare, self-provisionable entitlement set that the
signing pipeline derives and reconciles with the selected profile: `application-identifier`,
`com.apple.developer.team-identifier`, and `get-task-allow` (true for development, false
for distribution). Capabilities such as app groups, keychain sharing, push, and other
geographically provisioned entitlements are out of scope for version 1 and must fail
loudly if requested until the capability-association support in
`docs/engineering-handover.md` is implemented.


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
  native shallow-app signing and verification, pinned public Apple signing trust, and
  IPA packaging.
- `Sources/DeviceKit` — native usbmux discovery, pair-record access, lockdown session
  TLS, AFC staging, installation proxy, bounded native USB installation, mDNS DNS-SD,
  remote-pairing Pair-Verify, the SRP-3072 Pair-Setup bootstrap, CoreDevice
  tunnel/run integration, and the native cancellable OpenSSL 3
  TLS-PSK/`CDTunnel` connection.
- `Sources/ProductCore` — product-level environment diagnostics used by `doctor`.
- `Sources/stupid-app` — the cross-platform CLI.
- `docs/rcodesign-pin.md` — the retired qualification signer and its historical pin.
- `docs/sdk-export-format.md` — the SDK bundle archive and manifest specification.
- `docs/engineering-handover.md` — the maintained engineering source of truth.
- `docs/implementation-notes.md` — the chronological engineering log.
- `skills/stupid-app-cli/` — agent-facing CLI usage skill distributed with the binary.
- `docs/clean-host-setup.md` — clean-host setup and recovery procedures.
- `docs/macos-clean-host-setup.md` — macOS Mode A / Mode B setup and recovery.
- `docs/mode-b-darwin-tools.md` — Gate M4 plan for macOS-hosted Darwin tools.

## Commands

```text
stupid-app --version              Print the product and toolchain version
stupid-app doctor                  Check toolchain, SDK, signer, credentials, and device dependencies
stupid-app new <name>              Scaffold a SwiftPM/SwiftUI iOS project
stupid-app sdk export ...          (macOS) export a device-only Swift SDK bundle
stupid-app sdk import <archive>    (Linux) validate and install an SDK bundle
stupid-app build                   Build an unsigned iOS .app with the imported SDK
stupid-app credentials add         Store ASC API key + team ID (0600 files)
stupid-app signing setup [...]     Bootstrap credentials + provision identities/profiles (see below)
stupid-app devices                  List App Store Connect devices
stupid-app device pair --usb        Pair lockdown natively, then bootstrap CoreDevice pairing
stupid-app run --usb                Build, sign, install, and launch over USB
stupid-app run --network --udid ... Build, sign, install, and launch over the network
stupid-app run --simulator [--udid] Build, sign, install, and launch in a simulator (Xcode-present)
stupid-app simulators               List simulator runtimes and devices
stupid-app release archive          Build, sign (once, no timestamps), package the IPA
stupid-app release upload --wait    Upload the IPA and wait for internal TestFlight
stupid-app release new-build        Suggest the next build number from the latest uploaded build
stupid-app release status           Report the last release's recorded or live state
```

`stupid-app signing setup` is the one-stop provisioning command:

```bash
# Fresh user: single ASC key bundles credentials + distribution + development provisioning
stupid-app signing setup --key-id <id> --issuer-id <id> --p8 <key.p8> --team-id <TEAM> \
  --bundle-id net.example.app --udid <device-udid>

# From a project directory, the bundle ID is read from stupid-app.yml (--bundle-id optional)
stupid-app signing setup --kind distribution --udid <device-udid>

# Reuse an identity/profile Xcode already manages (macOS)
stupid-app signing setup --kind distribution --from-xcode
```

- `--kind` is repeatable and defaults to both `distribution` and `development` when
  omitted; `--bundle-id` is repeatable and, when omitted, is read from `stupid-app.yml`
  in the current directory.
- Credential options (`--key-id`, `--issuer-id`, `--p8`, `--team-id`) store the App Store
  Connect key and team ID when supplied, so a fresh user may skip a separate
  `credentials add`.
- Development provisioning runs only when `--udid` is provided (a physical device must
  be registered); otherwise it is skipped with a note.
- `--from-xcode` (macOS only) imports an existing Keychain identity and the exact
  Xcode-managed provisioning profile for the bundle instead of minting new credentials.

`stupid-app doctor` exits unsuccessfully when a required host dependency is invalid
and reports incomplete credentials, signing identities, pairing, or project context as
warnings. It checks the installed SDK against the current host triple and Swift
major/minor version, validates the bundled Apple WWDR/root trust, OpenSSL 3.x, and the
native CoreDevice helper,
checks owner-only credential and pairing-record modes without reading or printing their
contents, and validates project configuration plus referenced files when run in a
project directory.

CoreDevice tunneling requires `/dev/net/tun` and `CAP_NET_ADMIN` on Linux (a `utun`
kernel-control socket on macOS). The CLI never elevates implicitly: run an
already-privileged helper or pass an explicit `--sudo`
path. Production setup should install the helper root-owned and grant only that exact
command in sudoers. Pairing records are stored under the permission-
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

Building `DeviceKit` requires OpenSSL 3.x (`libssl-dev` on Ubuntu or `openssl@3` via
Homebrew). USB auto-discovery, existing pair-record loading, lockdown session TLS, and
USB installation use the native usbmux, AFC, and installation-proxy clients. Fresh
pairing, remote pairing, network tunneling, RSD, and AppService are also native; no
Python stack is required.

## License and provenance

Adapts design concepts from xtool (MIT). The retired `rcodesign` qualification path was
MPL-2.0 (see `docs/rcodesign-pin.md`), and the vendored LZFSE encoder is BSD-3-Clause
(see `THIRD_PARTY_NOTICES.md`). The native signer bundles only Apple's public WWDR G3
intermediate and Apple Inc. root certificates, pinned by DER SHA-256. See
`docs/implementation-notes.md` for provenance and the engineering handover for the
current architecture and gates.
