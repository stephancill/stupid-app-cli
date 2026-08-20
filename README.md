# stupid-app

A CLI for creating, building, signing, wirelessly deploying, and releasing iOS
applications without requiring Xcode or macOS at runtime.

`stupid-app` produces real Apple-signed apps with a native signing engine, installs
them over USB or the network onto a physical iPhone, and uploads distribution IPAs to
App Store Connect through the public API. It runs on macOS and Linux.

## Installation

### macOS (Apple Silicon)

Download the `stupid-app-macos-arm64` binary from the
[releases page](https://github.com/stephancill/stupid-app-cli/releases) and put it on
your `PATH`:

```bash
curl -fsSL -o /usr/local/bin/stupid-app \
  https://github.com/stephancill/stupid-app-cli/releases/latest/download/stupid-app-macos-arm64
chmod +x /usr/local/bin/stupid-app
stupid-app --version
```

### Linux

Build from source with a Swift 6.2 toolchain (x86_64 Ubuntu 24.04 LTS):

```bash
git clone https://github.com/stephancill/stupid-app-cli.git
cd stupid-app-cli
swift build -c release
sudo install -m 755 .build/release/stupid-app /usr/local/bin/stupid-app
stupid-app --version
```

Verify the installation with `stupid-app doctor` once you have imported an iOS SDK
bundle or Xcode installed.

### Optional: install the agent skill (recommended)

The repository ships an agent-facing usage skill at `skills/stupid-app-cli/`. Install it for
your AI tooling so agents can consult it whenever they operate the CLI:

```bash
npx skills add stephancill/stupid-app-cli
```

Without this step the CLI works identically; the skill only adds agent guidance.

## Supported platforms

- **Linux:** x86_64 Ubuntu 24.04 LTS — the primary deployment host for building,
  signing, and releasing iOS apps.
- **macOS:** Apple Silicon macOS 14+ — build against Xcode's SDK in place, or from an
  imported SDK bundle (Xcode-absent mode), including a simulator run loop.

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
native CoreDevice helper, checks owner-only credential and pairing-record modes without
reading or printing their contents, and validates project configuration plus referenced
files when run in a project directory.

CoreDevice tunneling requires `/dev/net/tun` and `CAP_NET_ADMIN` on Linux (a `utun`
kernel-control socket on macOS). The CLI never elevates implicitly: run an
already-privileged controlled helper or pass an explicit `--sudo` path. Production
updates of the helper must be deployed in a controlled, audited manner.

Pairing records are stored under the permission-hardened credential directory.

## Package layout

- `Sources/SDKCore` — cross-platform primitives: SHA-256 wrapper (`swift-crypto`),
  the SDK export manifest model, host triple / Swift version probing, and safe archive
  listing/validation.
- `Sources/ProjectCore` — the typed `stupid-app.yml` schema and project generator.
- `Sources/BuildCore` — SwiftPM planning, unsigned `.app` assembly (including
  `PlugIns/*.appex` extensions from the `extensions:` config), SDK-version
  discovery, native app-icon generation and `Assets.car` writing (`swift-png`), and
  Mach-O inspection.
- `Sources/CLZFSE` — Apple's pinned BSD-3-Clause LZFSE reference implementation used
  for compressed native asset-catalog payloads.
- `Sources/ASCKit` — App Store Connect ES256 JWT, HTTP client, and bundle-ID /
  certificate / profile / Build Upload operations; permission-hardened credential
  storage; the release manifest.
- `Sources/SigningKit` — provisioning-profile CMS parsing, entitlement derivation
  (including App Groups), native shallow and deep (extension) signing and
  verification, pinned public Apple signing trust, and IPA packaging.
- `Sources/DeviceKit` — native usbmux discovery, pair-record access, lockdown session
  TLS, AFC staging, installation proxy, bounded native USB installation, mDNS DNS-SD,
  remote-pairing Pair-Verify, the SRP-3072 Pair-Setup bootstrap, CoreDevice
  tunnel/run integration, and the native cancellable OpenSSL 3
  TLS-PSK/`CDTunnel` connection.
- `Sources/ProductCore` — product-level environment diagnostics used by `doctor`.
- `Sources/stupid-app` — the cross-platform CLI.
- `docs/sdk-export-format.md` — the SDK bundle archive and manifest specification.
- `docs/engineering-handover.md` — the maintained engineering source of truth.
- `docs/implementation-notes.md` — the chronological engineering log.
- `docs/clean-host-setup.md` — clean-host setup and recovery procedures.
- `docs/macos-clean-host-setup.md` — macOS setup and recovery.
- `skills/stupid-app-cli/` — agent-facing CLI usage skill distributed with the binary.

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

Adapts design concepts from xtool (MIT). The vendored LZFSE encoder is BSD-3-Clause
(see `THIRD_PARTY_NOTICES.md`). The native signer bundles only Apple's public WWDR G3
intermediate and Apple Inc. root certificates, pinned by DER SHA-256. See
`docs/implementation-notes.md` for provenance and the engineering handover for the
current architecture.