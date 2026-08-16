# Engineering Handover

## Document Purpose

This document is the current engineering source of truth for the project. Read it before planning or changing code. Update it whenever implementation changes the scope, architecture, command surface, compatibility matrix, security model, acceptance criteria, known risks, or recommended next work.

Historical work belongs in `docs/implementation-notes.md`. This document should describe the project as it exists now, not preserve obsolete plans.

## Current Status

The project is in technical validation. Gate 0 (SDK and compiler proof) is complete: a
device-only, checksummed iPhoneOS Swift SDK bundle is exported on macOS by
`stupid-app sdk export`, validated and imported on the isolated `iosdev-ubuntu` WSL host
by `stupid-app sdk import`, and a minimal SwiftUI app compiles and links to an ARM64
Mach-O using the imported SDK.

Gate 1 (distribution signing proof) is complete on the isolated WSL host. The CLI now
scaffolds projects (`stupid-app new` + `stupid-app.yml`), plans and assembles an
unsigned `.app` with the imported SDK (`stupid-app build`), manages permission-hardened
App Store Connect credentials and a distribution identity (`stupid-app credentials add`,
`stupid-app signing setup --kind distribution`), and produces a real Apple
Distribution-signed IPA with `stupid-app release archive`. The pinned `rcodesign`
0.29.0 signing kernel (prebuilt musl binaries, no Rust on target hosts) signs once with
timestamps disabled; the output was independently verified with the project's own
checks and with macOS `codesign --verify --strict`. See `docs/rcodesign-pin.md` for the
signer pin and `docs/implementation-notes.md` for verification details.

Gate 2 (Linux Build Upload proof) is complete on the isolated WSL host. The App Store
Connect Build Upload client (`POST /v1/buildUploads`, `POST /v1/buildUploadFiles`,
execution of returned `DeliveryFileUploadOperation`s, `PATCH` commit with source
checksums), exact-build resolution by app + marketing version + build number, and
processing/internal-beta polling live in `ASCKit`; `stupid-app release upload --wait`
uploads a distribution IPA and writes the release manifest. The accepted Linux-built
IPA uses the native `Assets.car` writer with pinned Apple LZFSE compression and nested
`CFBundleIconName` metadata matching `actool`; App Store Connect reported the build
`VALID` and `READY_FOR_BETA_TESTING`. The build installed through TestFlight and
launched successfully. See "Live Gate 2 Upload Findings" below.

Gate 3 (development signing proof) is complete on the isolated WSL host. Device
registration, development certificate/profile creation, entitlement reconciliation,
one-pass signing, IPA packaging, USB installation, and launch were exercised on a
physical iPhone. WSL USBIP required a qualified `usbmuxd` 1.1.1 build using 16,383-byte
short-packet transfers; the stock 49,152-byte transfer size is corrupted by USBIP.
Launch on iOS 26.6 required a privileged USB-bootstrapped CoreDevice tunnel because
the legacy DVT lockdown service returns `InvalidService`. The proof is complete, but
integrating that privileged tunnel lifecycle into `run --usb` remains Gate 4 work.

Product and executable naming is decided: the CLI and package are `stupid-app`, the
project-level configuration file is `stupid-app.yml`, the SDK artifact ID is
`stupid-app-ios`, and the SDK exporter is the `sdk export` subcommand of the same tool
rather than a standalone executable. The WSL distribution name `iosdev-ubuntu` remains
unchanged.

## Product Goal

Create a CLI that supports a complete iOS application workflow without requiring Xcode or a Mac during normal development and release operations:

1. Create a new iOS project from scratch on a supported non-macOS host.
2. Cross-compile and package a SwiftPM/SwiftUI application for a physical iPhone.
3. Provision and sign it with a real Apple Development certificate.
4. Install and launch it wirelessly on an iPhone after one USB trust and pairing bootstrap.
5. Produce a real Apple Distribution-signed IPA.
6. Upload the IPA without `xcrun`, `altool`, or Transporter.
7. Wait until App Store Connect reports a valid build ready for internal TestFlight.

Successful TestFlight processing and installation are the release correctness proof. Creating a ZIP named `.ipa` or completing an upload request is not sufficient.

## Locked Product Decisions

- A paid Apple Developer Program membership is required.
- Authentication uses an App Store Connect team API key and public APIs. Apple ID password, anisette, GrandSlam, and other private authentication APIs are out of scope.
- Version 1 supports CLI-owned SwiftPM applications with code-based SwiftUI interfaces.
- Version 1 targets physical ARM64 iPhones. Simulator execution is out of scope.
- One USB connection to the deployment host is acceptable for initial iPhone trust and pairing. Subsequent development runs must work over the local network.
- Device and release builds must use real Apple certificates. The pipeline must not pseudo-sign or ad-hoc sign an application as an intermediate step.
- The exact configured bundle identifier is retained. Do not add xtool-style `XTL-*` prefixes.
- The release artifact is a distribution-signed IPA plus a release manifest. An `.xcarchive` is not required for App Store Connect upload.
- App extensions are not part of the first supported project model. The architecture must not preclude adding per-bundle extension signing later.
- An isolated x86_64 Ubuntu 24.04 WSL 2 distribution is the initial Gate 0 build host. Renting a VPS and integrating the existing low-resource Raspberry Pi are deferred until a concrete need remains after WSL validation.
- No timeline estimates belong in planning documents. Use ordered gates and, only when useful, relative point estimates.

## Acceptance Criteria

### Project Creation And Build

On a clean supported Linux host:

```bash
stupid-app sdk import ios-sdk.tar.zst
stupid-app new AcceptanceApp
cd AcceptanceApp
stupid-app build
```

Acceptance conditions:

- Project creation does not invoke Xcode.
- The generated package builds with the imported Swift SDK.
- The application executable is ARM64 Mach-O, not ELF.
- The bundle contains a valid `Info.plist`, executable, resources, and expected minimum iOS version.
- Unsupported project inputs fail during planning with a clear diagnostic.

### Development Signing And Wireless Run

On a supported Linux deployment host on the same LAN as the iPhone:

```bash
stupid-app device pair --usb
stupid-app run --network --udid <udid>
```

Acceptance conditions:

- The iPhone is disconnected from USB before the run command.
- The IPA uses an Apple Development certificate and an iOS development provisioning profile.
- The signed entitlements agree with the embedded profile and include `get-task-allow=true`.
- Installation reaches 100 percent and the app launches.
- Three consecutive clean runs succeed without killing stale helper processes manually.
- No pseudo-signing or ad-hoc signing operation occurs.

### Distribution And TestFlight

```bash
stupid-app release archive
stupid-app release upload --wait
```

Acceptance conditions:

- The IPA uses an Apple Distribution certificate and an iOS App Store profile.
- The profile has no provisioned-device list.
- Signed entitlements include `get-task-allow=false` and are authorized by the profile.
- The exact IPA version and build number have not previously been uploaded.
- App Store Connect Build Upload completes.
- App Store Connect reports the resulting build as `VALID` and ready for internal beta testing.
- The build installs and launches through TestFlight.
- A release manifest records artifact hash, bundle ID, versions, upload resource ID, build resource ID, and processing state.

## Supported Project Model

The first generated project should resemble:

```text
AcceptanceApp/
|-- Package.swift
|-- stupid-app.yml
|-- Info.plist
|-- App.entitlements
|-- Resources/
|   `-- AppIcon.png
`-- Sources/
    `-- AcceptanceApp/
        |-- AcceptanceApp.swift
        `-- ContentView.swift
```

Example `stupid-app.yml`:

```yaml
version: 1
product: AcceptanceApp
bundleID: net.example.acceptance-app
deploymentTarget: "17.0"
infoPath: Info.plist
entitlementsPath: App.entitlements
iconPath: Resources/AppIcon.png
```

Initial supported inputs:

- One SwiftPM library product representing the application.
- Swift, Foundation, and SwiftUI source.
- SwiftPM resource bundles.
- Explicit raw resources.
- PNG app icons generated from one square source image.
- Pure Swift dependencies that cross-compile successfully.
- Compatible C-family or binary dependencies only after explicit fixture coverage exists.

Inputs that must initially fail loudly:

- Xcode projects and workspaces as build inputs.
- Storyboards and XIB files.
- Asset catalogs requiring `actool` compilation.
- Core Data models requiring `momc`.
- Metal source requiring Apple tooling.
- Arbitrary Xcode build phases.
- Build tool plugins or macros not validated on the host and target pair.
- App extensions.
- ExtensionKit products.

## Proposed Command Surface

```text
stupid-app doctor
stupid-app sdk export <host-triple>   (macOS only)
stupid-app sdk import <archive>
stupid-app new <name>
stupid-app build [--configuration debug|release]
stupid-app credentials add
stupid-app signing setup --kind distribution
stupid-app signing setup --kind development
stupid-app devices
stupid-app device pair --usb
stupid-app run --usb [--udid <udid>]
stupid-app run --network --udid <udid>
stupid-app release archive
stupid-app release upload [--wait]
stupid-app release status
```

Implemented so far: `new`, `sdk export`, `sdk import`, `build`, `credentials add`,
`signing setup --kind distribution|development`, `devices`, `run --usb`,
`release archive`, and `release upload --wait`. The `doctor`, `device pair`,
`run --network`, and `release status` commands are not yet implemented.

The command surface is provisional until the proof gates complete. Keep build, signing, install, launch, upload, and status as separable operations even if convenience commands compose them.

## Recommended Architecture

### CLI And Process Model

The current recommendation is a Swift CLI because the supported host already needs a Swift toolchain and xtool's planner and packer can be extracted with less translation risk. Use Swift Argument Parser or the repository's selected equivalent.

Do not copy xtool's large development command wholesale. Keep these concerns as independent modules:

- Configuration and project schema. (`ProjectCore`)
- SDK import and compatibility checks. (`SDKCore`)
- SwiftPM graph planning. (`BuildCore`)
- Compilation and unsigned bundle assembly. (`BuildCore`)
- App Store Connect authentication and APIs. (`ASCKit`)
- Certificate and provisioning profile management. (`SigningKit` + `ASCKit`)
- Entitlement derivation and validation. (`SigningKit`)
- Code-signing adapter. (`SigningKit`)
- IPA packaging and verification. (`SigningKit`)
- Device listing and USB installation adapter. (`DeviceKit`, USB install proven;
  CoreDevice launch integration remains)
- Build Upload and TestFlight processing. (`ASCKit`, transport proven)

### SDK Export And Import

Normal Linux use depends on a pre-exported, checksummed, device-only Swift SDK bundle. Xcode is needed only to prepare this bundle.

Preferred preparation flow on a Mac:

```bash
stupid-app sdk export \
  --xcode /Applications/Xcode.app \
  --host <linux-host-triple> \
  --target arm64-apple-ios \
  --output <output-directory>
```

The Linux CLI then validates and imports it:

```bash
stupid-app sdk import ios-sdk.tar.zst
stupid-app doctor
```

The bundle should contain only what the physical-device target requires:

- The selected iPhoneOS SDK.
- Swift runtime and static runtime resource libraries.
- Clang resource files.
- Required iPhoneOS platform frameworks, private frameworks, and platform libraries.
- Linux-hosted `ld64.lld`, `libtool`, and `dsymutil`.
- Swift SDK `info.json`, `swift-sdk.json`, and `toolset.json`.
- A canonical content checksum manifest.
- Generator version, source Xcode version and build, iPhoneOS SDK version, Swift compiler compatibility, host triple, and target triple metadata.

Import requirements:

- Verify the archive and every declared file before installation.
- Reject absolute paths, path traversal, and escaping symlinks.
- Reject a host triple or architecture mismatch.
- Reject an unsupported host Swift/Xcode SDK pairing.
- Install into a temporary sibling directory and activate with an atomic rename.
- Keep the prior working SDK until the replacement passes a smoke compilation.
- Allow multiple versioned SDKs to coexist.
- Do not distribute Apple SDK payloads in repository releases.

The first compatibility pair should be explicitly pinned after the SDK/build proof succeeds. Xcode 26 and Swift 6.2 are the current research baseline, not yet a validated project guarantee.

### Build And Bundle Assembly

Adapt the design in xtool's `Sources/PackLib`:

1. Ask SwiftPM for machine-readable package description and dependency data.
2. Select the configured application library product.
3. Create a synthetic executable target that depends on that product.
4. Build it with the imported `arm64-apple-ios` Swift SDK.
5. Assemble an unsigned `.app` with the executable, merged `Info.plist`, SwiftPM resource bundles, supported raw resources, frameworks, and libraries.
6. Validate architecture, load commands, deployment target, paths, and bundle metadata.

Correct known xtool weaknesses while extracting this design:

- Use the actual SDK version in linker platform metadata, not the deployment target.
- Record complete compiler and SDK build identifiers.
- Resolve tools through injected configuration rather than hard-coded macOS paths.
- Reject unsupported resources instead of copying them as if compiled.
- Keep generated and persistent release files in separate directories.
- Emit the App Store-required build-system Info.plist keys (`DTPlatformName`,
  `DTPlatformVersion`, `DTSDKName`, `DTXcode`, `DTXcodeBuild`, `DTCompiler`) from the
  SDK export manifest, and never emit `BuildMachineOSBuild` on Linux.
- Generate the app icon set natively with `swift-png` (`IconGenerator`), and generate
  a compiled `Assets.car` with the native writer (`AssetCatalogWriter`) so builds
  always embed a real asset catalog.

### Authentication And Apple APIs

Required user inputs:

- App Store Connect team API key ID.
- App Store Connect issuer ID.
- App Store Connect `.p8` private key.
- Apple Developer team ID.
- Paid Apple Developer Program membership.

A team key with App Manager or Admin access is the recommended initial setup. Validate the minimum role empirically and narrow the requirement if possible.

The API key should authorize:

- Bundle ID registration.
- Device registration.
- Development and distribution certificate creation.
- Development and App Store profile creation.
- Build Upload creation and completion.
- Build and TestFlight status queries.

An App Store Connect app record remains a one-time manual prerequisite because the public API does not create app records.

Do not implement Apple ID password login or private authentication as a fallback.

### Certificate And Credential Storage

The CLI should support generating and importing separate identities for development and distribution.

Generated identity flow:

1. Generate an RSA-2048 private key.
2. Generate a CSR.
3. Request the appropriate certificate through App Store Connect.
4. Download and verify the certificate.
5. Verify that the certificate matches the private key.
6. Store the PEM identity in the permission-hardened credential directory.

Storage requirements:

- Credential directories use mode `0700`.
- Secret files use mode `0600`.
- Writes are atomic.
- Secret files are plaintext and readable only by the owning account and root/sudo.
- No credential passphrase or `STUPID_APP_CREDENTIAL_PASSWORD` is used.
- Credential reads fail loudly; they do not fall back to legacy ASC environment
  variables after a store error.
- Secrets never appear in command output, logs, manifests, shell history, repository files, or crash reports.
- The App Store Connect API key and Apple signing identities remain separate credentials.
- Imported profiles and certificate metadata may be cached, but private key material must never be copied into release artifacts.

### Provisioning And Entitlements

Requested entitlements come directly from `App.entitlements`. They must never be recovered from a temporary pseudo-signature.

Before signing, validate at least:

- Certificate and private key match.
- Certificate is active, currently valid, and of the correct development or distribution type.
- Profile is active, unexpired, and of the expected type.
- Profile contains the selected certificate.
- Profile application identifier permits the exact bundle ID.
- Team identifiers agree across profile, certificate, and generated entitlements.
- Requested entitlements are authorized by the profile.
- Keychain groups and application groups are profile-authorized when present.
- Development mode produces `get-task-allow=true`.
- Distribution mode produces `get-task-allow=false`.
- App Store profiles have no device list.

The public API can enable several capabilities but cannot associate every concrete resource, including App Group identifiers. Complex capabilities are therefore deferred from the initial application fixture. When added, any required Developer portal web step must be explicit and profile output must be verified afterward.

### Signing Engine

Use `apple-codesign`/`rcodesign` as the initial low-level signing engine. It has
stronger implementations of Mach-O signing, nested bundle traversal, resource sealing,
CMS, and XML/DER entitlements than xtool's current Zupersign integration.

**Sourcing decision (Gate 1):** provision `rcodesign` per target host as a pinned
**prebuilt release binary**, not a source compile. Upstream publishes statically linked
`musl` binaries per architecture for every release, so no Rust toolchain is required on
any supported host. The pinned source checkout lives in the ignored
`third-party/apple-platform-rs` directory for auditability only. The exact pin,
license (MPL-2.0), per-architecture checksums, and the macOS reproduction build are
recorded in `docs/rcodesign-pin.md`.

Treat it as a signing kernel, not an iOS workflow solution. The project must implement:

- Mobile provisioning profile parsing and validation.
- Profile embedding.
- Final entitlement derivation.
- Per-bundle signing configuration when extensions are introduced.
- IPA construction.
- iOS-specific post-sign validation.

Gate 1 implemented: profile CMS plist extraction (`MobileProvisionParser`), final
entitlement derivation and profile reconciliation (`EntitlementDeriver`), profile
embedding, one-signing-pass distribution signing with timestamps disabled
(`RcodesignSigner`), and IPA packaging/verification (`IPAPacker`).

Requirements for the proof:

- Disable signing timestamps for iOS distribution signing. Timestamped distribution
  signatures have caused App Store rejection. (Implemented: `--timestamp-url none`.)
- Pin the exact validated binary or source revision and its checksum. (Recorded in
  `docs/rcodesign-pin.md`.)
- Compare signature structure against known-good Xcode-produced artifacts.
- Run independent CMS, CodeDirectory, entitlement, and resource-seal checks.
- Use completed App Store Connect processing and TestFlight installation as the final
  authority.

Gate 1 used the project's own Mach-O/signature inspection plus macOS
`codesign --verify --strict` as independent checks. App Store processing and TestFlight
installation are the Gate 2 proof.

Do not add a Zupersign fallback. Fail loudly if the validated signer is unavailable or
its output fails verification.

### Signing Pipelines

Development:

```text
SwiftPM build
-> unsigned app assembly
-> device registration
-> Apple Development certificate and profile selection
-> requested entitlement and profile reconciliation
-> embedded.mobileprovision
-> one real signing pass
-> verification
-> IPA
-> wireless install and launch
```

Distribution:

```text
SwiftPM release build
-> unsigned app assembly
-> Apple Distribution certificate and App Store profile selection
-> distribution entitlement and profile reconciliation
-> embedded.mobileprovision
-> one real signing pass with timestamps disabled
-> verification
-> Payload/App.app IPA
-> immutable release manifest
-> Build Upload API
-> processing and TestFlight status polling
```

Neither pipeline may include an ad-hoc or pseudo-signing pass.

### Device Pairing And Wireless Deployment

Initial direction:

- Use `usbmuxd` and libimobiledevice-compatible tooling for initial USB trust and pairing.
- Store pairing records as credentials.
- Use a pinned `pymobiledevice3` integration for modern CoreDevice remote pairing, tunnel, installation, and launch until a reliable native implementation exists.
- Include timeout, cancellation, and process cleanup inside the CLI rather than requiring operator scripts.
- Do not require LLDB attachment for a successful run.
- Make the deployment transport replaceable so a future Raspberry Pi or LAN agent can receive a development-signed IPA from the WSL or another Linux build host.

The current WSL host is on the same physical LAN as the iPhone and uses WSL mirrored
networking, making it a better wireless test environment than a public VPS.
`usbipd-win` is installed and USB pass-through, trust/pairing, development installation,
and USB-bootstrapped CoreDevice launch were validated. CoreDevice launch requires
privileged TUN creation. Modern network discovery, remote pairing, unplugged tunneling,
and repeatability still depend on mDNS, pairing records, IPv6 behavior, and privileged
route cleanup and remain unverified.

### App Store Connect Upload

Use the public Build Upload resources instead of `altool` (implemented in `ASCKit`):

1. Create a build upload for the app, platform, marketing version, and build number.
2. Create the IPA build-upload file.
3. Execute every returned upload operation with the exact URL, method, headers, byte range, and checksum requirements.
4. Mark the file uploaded with source checksums.
5. Poll the build upload until complete or failed.
6. Resolve the exact resulting build by app, marketing version, and build number.
7. Poll build processing and beta details until the selected readiness state is reached.

`BuildUploader` in `Sources/ASCKit/BuildUploader.swift` orchestrates the full flow:
create Build Upload, reserve the file, execute `DeliveryFileUploadOperation`s, commit
with source checksums, poll to a terminal upload state, resolve the exact build by
app + marketing version + build number, and poll processing plus `buildBetaDetail` to
internal TestFlight readiness. Checksum verification and beta-readiness state
transitions are pure functions with unit tests. Delivery uploads run through
`ASCClient.rawRequest` so presigned URLs that carry their capability are never logged.

Do not identify builds using a generic "latest" query when an upload-specific identifier is available.

The release manifest (`Sources/ASCKit/ReleaseManifest.swift`) is public-safe and
written by `stupid-app release upload` to `.release/release-manifest.json`. It
contains:

- Bundle ID.
- Marketing version.
- Build number.
- IPA path relative to the project where possible.
- IPA SHA-256.
- Build Upload resource ID.
- App Store Connect build resource ID.
- Upload and processing state.
- Tool, signer, SDK, and compiler versions.

It must not contain API credentials, private keys, profile content, personal contact data, or certificate private material.

## Hosting Baseline

### Active WSL Test Host

The active Gate 0 environment is a dedicated WSL distribution named `iosdev-ubuntu`. It does not modify or depend on the machine's pre-existing Ubuntu or Docker WSL distributions.

Validated baseline:

- WSL 2 version 2.7.11.0.
- WSL kernel 6.18.33.2.
- Ubuntu 24.04.4 LTS.
- x86_64 host triple.
- Swift 6.2.4 installed with Swiftly 1.1.2.
- Swiftly archive verified with the swift.org PGP key set before installation.
- Swift toolchain signature verification completed during installation.
- Approximately 31 GB RAM and 8 GB swap exposed to WSL.
- Mirrored WSL networking enabled through the Windows `.wslconfig`.
- Approximately 955 GB free in the new sparse WSL filesystem at creation time.
- Native build prerequisites installed, including Clang, CMake, Ninja, Git, Curl, OpenSSL development files, ICU development files, XML, SQLite, Python 3, ZIP tools, and standard build-essential packages.

Useful commands from Windows:

```powershell
wsl.exe --distribution iosdev-ubuntu --user iosdev
wsl.exe --distribution iosdev-ubuntu --user iosdev --exec bash -lc ". ~/.local/share/swiftly/env.sh && swift --version"
wsl.exe --terminate iosdev-ubuntu
```

The prepared reusable image is stored outside the repository:

```text
C:\WSL\images\iosdev-ubuntu-base-20260816.tar.gz
SHA-256: 5EB146BDF52F27C22881C5F61D544836571F02EB1A0E001534CAE27E69428ED8
Compressed size: approximately 2 GB
```

Example isolated restore:

```powershell
wsl.exe --import iosdev-ubuntu-clone C:\WSL\iosdev-ubuntu-clone C:\WSL\images\iosdev-ubuntu-base-20260816.tar.gz --version 2
wsl.exe --manage iosdev-ubuntu-clone --set-default-user iosdev
```

The image contains no project signing credentials or Apple SDK payload. Re-export and update the checksum after intentionally changing the base image.

Current WSL limitations and follow-up:

- `usbipd-win` is installed; a physical iPhone was passed through to WSL and its
  existing pairing record validated successfully.
- USB installation and launch are proven. Stock `usbmuxd` 1.1.1 uses a 49,152-byte
  transfer unit whose ZLP boundaries are lost through WSL USBIP, causing the device to
  reject coalesced frames. A qualified 1.1.1 build with `USB_MTU=16383` forces a short
  packet boundary and completed installation. This patch is not yet provisioned by the
  CLI and its GPL-3.0 distribution implications must be handled explicitly.
- Mirrored networking is configured, but iPhone mDNS discovery, remote pairing, TUN
  setup, network installation, and launch remain unverified.
- The iOS Swift SDK has been exported and imported; a minimal SwiftUI app builds and links for `arm64-apple-ios`.
- The host Swift compiler is proven for both native Linux compilation and iOS cross-compilation.
- WSL is x86_64, so the SDK bundle must include x86_64 Linux Darwin tools and declare only the actual host triple.
- The WSL host requires the `zstd` package as a build prerequisite for `tar --zstd` archives.

Operational controls:

- Keep signing credentials in the `0700` credential directory as owner-only `0600`
  files and outside project directories.
- Treat WSL exports, virtual disks, Windows backups, and snapshots as secret-bearing once credentials are added.
- Do not place Apple SDK exports in this repository or reusable public images.
- Keep sufficient free space for multiple SDKs, Swift module caches, dependency checkouts, and release artifacts.
- Keep the existing Ubuntu and Docker distributions unchanged; run project experiments only in `iosdev-ubuntu` or a clone of its base image.

A VPS remains an optional later host for unattended build and release work. If introduced, start with at least 4 vCPUs, 8 GB RAM, and 80 GB SSD, and validate a separate host-triple SDK bundle.

## Implementation Reference Index

This section is intended to save implementation engineers from repeating the initial repository survey. Read the referenced source before adapting it; do not treat line references as a substitute for understanding the complete symbol and its dependencies.

### Reference Snapshot

The line ranges below were verified against these local snapshots:

- xtool commit `ee31b666bb1dc324c26183b92d11bab96d0af355` at `~/environments/external/xtool`.
- App Store Connect OpenAPI specification commit `7ca338b02ceba330ba3dbe40b350f6ef1459da5c` at `~/environments/external/App-Store-Connect-OpenAPI-Spec`.
- `pymobiledevice3` version `8.2.1`, with a locally installed reference copy under `~/.local/lib/python3.12/site-packages/pymobiledevice3`.

The local Python installation is only a readable reference. The project must pin and verify its own `pymobiledevice3` distribution rather than depending on that path. `apple-platform-rs` is not currently checked out locally; fetch a pinned revision into an ignored `third-party/` directory before Gate 1 and record its revision and MPL-2.0 license obligations.

When external source moves, prefer the named type or function over the recorded line range and update this index after validating the new revision.

### Gate-To-Source Map

| Gate | Read first | Expected implementation output |
| --- | --- | --- |
| Gate 0: SDK and compiler | `SDKBuilder.swift`, `SDKCommand.swift`, `PackLib/BuildSettings.swift`, `PackLib/Packer.swift` | Versioned SDK export manifest, safe importer, smoke-build harness |
| Gate 1: distribution signing | `ASCKey.swift`, certificate/profile operations, release script certificate/profile functions, `apple-codesign` source | Distribution identity/profile manager, entitlement reconciliation, signed IPA |
| Gate 2: Build Upload | OpenAPI `buildUploads` schemas, release script build-number/polling/manifest functions | Direct upload client, exact-build resolver, release manifest |
| Gate 3: development signing | xtool device/certificate/profile provisioning operations | Development identity/profile flow and USB-installable IPA |
| Gate 4: wireless transport | `PyMobileDevice3NetworkBridge.swift`, Termux handoff, pinned `pymobiledevice3` source | Pair, discover, tunnel, install, launch with bounded cleanup |
| Gate 5: product CLI | `XTool.swift`, `NewCommand.swift`, `PackSchema.swift`, process helpers | Stable command surface, typed config, diagnostics, tests and docs |

### xtool Package Boundaries And Dependencies

Start with `~/environments/external/xtool/Package.swift`:

- Lines 22-52 declare external dependencies. Candidate reusable Swift packages include Argument Parser, Swift System, Swift HTTP Types, Swift Certificates, Swift Crypto, Swift OpenAPI Runtime, Swift OpenAPI URLSession, Swift NIO, Async HTTP Client, Swift Dependencies, Concurrency Extras, Version, and Yams.
- Lines 23-25 declare `xtool-core`, `SwiftyMobileDevice`, and `zsign`. Do not inherit these automatically. In particular, do not bring the Zupersign signing path into the new package.
- Lines 64-99 show XKit's dependency concentration. This is a warning against importing XKit wholesale: it combines public APIs, private Apple authentication, native device libraries, signing, OpenSSL shims, and Linux anisette support.
- Lines 135-147 define `DeveloperAPI` and `XKit`; lines 169-180 define `XToolSupport` and `PackLib`. Extract narrow source into new targets rather than making the new CLI depend on the entire xtool package.
- Lines 175-180 show that `PackLib` itself has a small portable core: `XUtils`, Yams, and a macOS-only XcodeGen dependency. Omit XcodeGen from the new package.

xtool is MIT licensed. If source is copied or substantially adapted, preserve the relevant notice from `~/environments/external/xtool/LICENSE.md` and record provenance in implementation notes and repository notices.

### CLI Registration And Cancellation

| Reference | Adapt | Avoid or correct |
| --- | --- | --- |
| `Sources/XToolSupport/XTool.swift:26-59` | Argument Parser command registration and grouped command organization | Do not mirror commands that expose private Developer Services authentication |
| `Sources/XToolSupport/XTool.swift:66-130` | `cancellableMain` signal handling that maps `SIGINT` and `SIGTERM` to Swift task cancellation | Ensure child processes also receive bounded termination and cannot survive cancellation |
| `Sources/PackLib/Process+Helpers.swift:3-63` | `Process.runUntilExit(onCancel:)`, exit-status handling, and explicit interrupt/terminate policy | Add timeout support, bounded stdout/stderr capture, escalation from interrupt to terminate/kill, and process-group cleanup |
| `Sources/PackLib/ToolRegistry.swift:15-59` | PATH-based tool lookup as a replaceable abstraction | Its shell lookup warns about quote injection; accept only fixed validated tool names or avoid shell evaluation |

Keep command implementations thin. The new CLI should call independently testable SDK, planner, build, signing, device, and upload operations rather than grow a replacement for xtool's approximately 1,700-line `DevCommand.swift`.

### SDK Export And Linux Import

Primary source: `~/environments/external/xtool/Sources/XToolSupport/SDKBuilder.swift`.

| Symbol or range | Useful behavior | Required change |
| --- | --- | --- |
| `SDKBuilder.Input`, lines 16-62 | Validates an extracted `Xcode.app` through `Contents/Developer` | Keep the `.app` path; do not make Linux XIP extraction part of the supported flow |
| XIP branches, lines 41-59 and 368-439 | Documents the former XIP path and its hardlink/extraction concerns | The dependency is disabled in this checkout. Do not restore it for normal Linux setup |
| `buildSDK()`, lines 69-185 | Creates a Swift SDK artifact bundle and writes `info.json`, `toolset.json`, and `swift-sdk.json` | Replace hard-coded `develop`/`0.0.1`, include one actual host triple, include only `arm64-apple-ios`, and record full Xcode/SDK/Swift metadata |
| SDK discovery, lines 89-115 | Finds platform SDK directories and creates relative SDK paths | Sort and require exactly one supported numeric SDK rather than choosing the first directory returned by the filesystem |
| `toolset.json`, lines 145-163 | Configures `ld64.lld`, cross-import overlays, and LLD | Also configure and validate `libtool` and `dsymutil` when required by the tested toolchain |
| `installToolset`, lines 187-233 | Selects x86_64 or aarch64 Linux Darwin tools and streams a tar archive | Pin source revision and SHA-256; verify before extraction; never pipe unverified bytes directly into `tar` |
| `installDeveloper`, lines 236-366 | Traverses Xcode and copies only selected files | Preserve symlinks deliberately, reject escaping links, normalize metadata, and make the selection device-only |
| `SDKEntry.wanted`, lines 441-526 | Compact allow-list tree for Swift/Clang resources and platform contents | Remove MacOSX and iPhoneSimulator entries; audit the TODO about over-including dylibs |

Related import source: `~/environments/external/xtool/Sources/XToolSupport/SDKCommand.swift`.

- `DarwinSDK`, lines 126-201, models installed SDK state.
- `DarwinSDK.install(from:)`, lines 142-155, delegates registration to `swift sdk install`. Keep this boundary because SwiftPM owns the SDK installation layout.
- `DarwinSDK.current()`, lines 157-192, parses `swift sdk configure ... --show-configuration`. Treat this as a compatibility probe, not a robust source of installation metadata.
- `isUpToDate()`, lines 194-196, currently always returns true. Replace it with manifest and toolchain compatibility checks.
- `InstallSDKOperation`, lines 239-265, provides a small orchestration reference for building and registering an SDK.

The exporter should read version information from Xcode's own metadata and SDK settings rather than inferring it from directory names alone. The importer must validate archive paths before extraction, verify every manifest digest, install to a temporary sibling directory, smoke compile, and atomically activate only on success.

### Project Generation And Configuration

Primary sources:

- `Sources/XToolSupport/NewCommand.swift:31-66` validates SwiftPM-compatible project names and derives a module name.
- `NewCommand.swift:68-168` writes a minimal package, config, SourceKit-LSP config, and SwiftUI app. Reuse the small template concept, not the implicit call to xtool setup at lines 25-29.
- `NewCommand.swift:70-96` demonstrates the one-library-product package shape required by the packer.
- `NewCommand.swift:123-131` configures SourceKit-LSP with the `arm64-apple-ios` Swift SDK.
- `NewCommand.swift:134-167` is a suitable minimal code-based SwiftUI fixture.
- `Sources/PackLib/PackSchema.swift:5-35` defines xtool's YAML schema fields.
- `PackSchema.swift:56-78` validates schema version, bundle-ID source, and PNG icon extension.
- `PackSchema.swift:86-90` decodes YAML with Yams.

The new schema should use an exact required bundle ID instead of xtool's optional `orgID` derivation. Validate all source paths relative to the project root, reject path escape, and reject unsupported resource extensions before invoking SwiftPM. Do not inherit extension fields until app extensions enter supported scope.

### SwiftPM Graph Planner

Primary source: `~/environments/external/xtool/Sources/PackLib/Planner.swift`.

| Symbol or range | Adapt | Caveat |
| --- | --- | --- |
| `buildGraph()`, lines 26-72 | Concurrently describes the root and dependency packages and constructs product ownership lookup | Product names are used as global keys; add ambiguity handling if dependencies expose duplicate names |
| `createPlan()`, lines 74-116 | Converts schema and graph information into application and extension plans | Version 1 should build only the application branch and reject extension configuration |
| Resource traversal, lines 130-162 | Walks target/product dependencies and records SwiftPM bundles, binary targets, dynamic libraries, and declared root resources | Add cycle-safe package-qualified target identity; the current visited set uses only target name |
| Info.plist synthesis, lines 164-205 | Derives deployment target, creates baseline bundle keys, and overlays a source plist | Replace the iOS 13 fallback at line 24 with the project's validated minimum; validate version and release-required metadata explicitly |
| `dumpDependencies()`, lines 220-236 | Uses `swift package show-dependencies --format json -o` to avoid noisy stdout | Preserve this workaround and test it against the pinned SwiftPM version |
| `dumpPackage()`, lines 238-247 | Uses `swift package describe --type json` and skips leading non-JSON output | Keep the recovery only for known SwiftPM noise; report malformed output with the command and bounded stderr |
| `selectLibrary`, lines 262-293 | Fails on zero, ambiguous, or mismatched app products | Retain this fail-loud behavior |
| `Plan`, lines 296 onward | Separates planning data from bundle construction | Simplify to one application in version 1 while keeping types extensible for future nested bundles |

Tests should include packages with one library, multiple libraries, a dynamic dependency, a binary XCFramework, SwiftPM resources, duplicate target names across packages, unsupported plugins, and paths containing spaces.

### Build Invocation And Unsigned Bundle Assembly

Primary sources:

- `Sources/PackLib/BuildSettings.swift:16-33` captures configuration, triple, package path, and `--swift-sdk` selection.
- `BuildSettings.swift:52-87` builds SwiftPM process invocations, locates `swift`, strips inherited `SDKROOT`, and adds package/configuration arguments.
- `Sources/PackLib/Packer.swift:13-86` creates a synthetic package whose executable target depends on the app library product. This is the central cross-platform packaging technique.
- `Packer.swift:64-68` adds an empty C source so SwiftPM emits the wrapper executable target.
- `Packer.swift:70-85` builds the synthetic package with a shared scratch path and disabled automatic resolution.
- `Packer.swift:88-126` builds into a temporary app directory and persists the assembled bundle.
- `Packer.swift:144-227` copies SwiftPM resource bundles, dynamic frameworks, dylibs, raw resources, the executable, icon, and generated `Info.plist`.
- `Packer.swift:175-190` distinguishes static archive frameworks from dynamic frameworks before embedding.
- `Packer.swift:205-226` adds physical-device metadata such as ARM64 capability and `CFBundleSupportedPlatforms`.
- `Packer.swift:230-263` emits `-platform_version` and runtime search paths.

Correct these issues during extraction:

- `Packer.activeSDKVersion()`, lines 128-142, returns the deployment target as the SDK version on non-macOS. Pass the actual SDK version from the imported manifest.
- Output is hard-coded under `xtool/` at lines 14-15 and 122-124. Define separate ephemeral build, credential, and persistent release roots.
- The packer copies declared root paths without classifying unsupported Apple resource formats. The new planner must reject these first.
- Build process output is redirected without a bounded diagnostic model. Capture a concise public-safe error plus a private diagnostic path.
- Preserve executable modes and symlinks and test both explicitly.

Do not adapt `Sources/PackLib/XcodePacker.swift`; it generates Xcode projects and is outside the non-macOS runtime architecture.

### App Store Connect JWT And HTTP Client

Primary public-auth source: `~/environments/external/xtool/Sources/XKit/DeveloperServices/OpenAPI/ASCKey.swift`.

- `ASCKey`, lines 4-14, is the minimal key ID, issuer ID, and PEM model.
- `ASCJWTGenerator`, lines 16-91, generates ES256 JWTs, uses a 15-minute TTL, renews with a two-minute tolerance, and emits the required raw P-256 signature representation.
- `ASCJWTGenerator.generate()`, lines 69-90, is a strong direct adaptation candidate after moving PEM storage behind the permission-hardened credential store.
- `Data.base64URLEncodedString()`, lines 93-100, implements unpadded base64url.

Cross-check against `~/.config/opencode/skills/appstore-release/scripts/release.sh:151-180`, whose `jwt()` helper independently demonstrates the required `aud=appstoreconnect-v1` payload and raw 64-byte `r || s` signature.

Use only the App Store Connect branch in `Sources/XKit/DeveloperServices/OpenAPI/DeveloperServices+OpenAPI.swift`. The password/Xcode-auth branches and `Sources/XKit/GrandSlam/` rely on private Apple protocols and are prohibited. Generate or hand-write only the API operations needed by this project and make HTTP status/error decoding explicit.

`Sources/XKit/DeveloperServices/OpenAPI/LoggingMiddleware.swift` is a warning rather than a ready logging layer: it can log complete API bodies. The new client must redact authorization headers, JWTs, `.p8` material, certificate content, profiles, upload URLs containing credentials, and personal identifiers.

### Key, Certificate, And Identity Management

| Reference | Adapt | Correct or replace |
| --- | --- | --- |
| `Sources/XKit/Model/Keypair.swift:31-61` | RSA-2048 generation and CSR construction using Swift Crypto and Swift Certificates | Replace hard-coded CSR subject values; verify whether the SHA-1 CSR signature at line 58 remains necessary or accepted before copying it |
| `Sources/XKit/Model/Certificate.swift:14-78` | DER certificate parsing, common-name/team extraction, serial normalization, validity comparison, and DER serialization | Add key-match, extended-key-usage, issuer-chain, certificate-type, and current-validity checks |
| `DeveloperServices/Certificates/DeveloperServicesFetchCertificateOperation.swift:60-82` | Generate key/CSR, create certificate through the public API, decode returned DER | It hard-codes `.development` at line 70; make certificate purpose explicit |
| `DeveloperServicesFetchCertificateOperation.swift:109-185` | Shows PKCS#12 reuse and server certificate matching concepts | The entire load path is guarded by Security.framework and returns nil on Linux. Replace it with portable PEM handling in the permission-hardened store |
| `DeveloperServicesFetchCertificateOperation.swift:230-264` | Detect missing or expired remote certificate state | Do not automatically revoke unrelated team certificates; select by stored certificate ID and fingerprint and require explicit destructive confirmation |
| `appstore-release/scripts/release.sh:649-707` | Distribution RSA key/CSR, `DISTRIBUTION` certificate creation, API response checks, and reuse intent | Replace macOS Keychain operations with the Linux permission-hardened credential store |
| `release.sh:423-459` | Match local identity fingerprint to an active App Store Connect certificate and verify profile certificate membership | Replace `security` CMS decoding with the project's portable profile/CMS parser |

`Sources/XKit/Utilities/KeyValueStorage.swift` provides a useful protocol boundary but not a secure Linux implementation. Its directory store does not enforce this project's mode and atomic-write requirements; its Keychain store is macOS-only.

### Bundle IDs, Capabilities, Profiles, And Entitlements

Development provisioning references:

- `DeveloperServices/DeveloperServicesProvisioningOperation.swift:40-59` sequences device registration, certificate selection, App ID/profile creation, and result assembly.
- `DeveloperServices/Devices/DeveloperServicesAddDeviceOperation.swift:10-35` registers a device and treats an existing-device conflict as recoverable.
- `DeveloperServices/App IDs/DeveloperServicesAddAppOperation.swift:41-154` gets or creates the exact bundle-ID resource and reconciles capabilities.
- `DeveloperServicesAddAppOperation.swift:159-233` reads bundle metadata, derives entitlements, creates the profile, and returns per-bundle provisioning information.
- `DeveloperServices/Profiles/DeveloperServicesFetchProfileOperation.swift:30-107` finds the exact bundle-ID resource, finds the certificate, attaches iOS devices, creates an `IOS_APP_DEVELOPMENT` profile, and decodes profile content.

Do not copy these behaviors:

- `DeveloperServicesAddAppOperation.swift:172-189` extracts requested entitlements by analyzing an already signed executable. Pass the source entitlement model into provisioning instead.
- `DeveloperServicesAddAppOperation.swift:197-204` always forces `get-task-allow=true`; distribution must force false.
- `DeveloperServicesFetchProfileOperation.swift:72-95` attaches every registered iOS-capable device. Version 1 should include only the selected development device; App Store profiles include no devices.
- `DeveloperServicesFetchProfileOperation.swift:52-61` may delete an existing profile before proving a replacement. Use the probe-first replacement pattern from the release script.
- `Sources/XKit/Utilities/ProvisioningIdentifiers.swift:15-27` adds the `XTL-*` prefix. Do not use any part that rewrites bundle identifiers.

Distribution profile references in `~/.config/opencode/skills/appstore-release/scripts/release.sh`:

- `register_bundle()`, lines 629-647, performs exact matching after the API's substring/prefix-like filter behavior.
- `ensure_app_groups_capability()`, lines 614-627, enables the capability but cannot associate concrete group identifiers.
- `create_profile_id()`, lines 709-719, creates `IOS_APP_STORE` profiles tied to one bundle-ID resource and certificate.
- `download_profile()`, lines 721-724, decodes `profileContent`.
- `profile()`, lines 731-801, exact-matches profile names, removes inactive profiles, validates a temporary replacement before deleting a usable profile, and handles one profile per bundle ID.
- `verify_profile_certificate()`, lines 445-459, and `verify_profile_app_groups()`, lines 462-476, demonstrate two required validation checks.

Profile parsing references:

- `Sources/XKit/Model/Mobileprovision.swift:12-73` wraps profile data and extracts a plist through native C helpers. Use its model shape only; the new project needs a portable CMS decoder and independent signature validation.
- `Sources/XKit/Model/Entitlements/` contains typed models for application identifier, team identifier, keychain groups, app groups, `get-task-allow`, push environment, and related capability mappings.
- `DeveloperServices/App IDs/Entitlements/DeveloperServicesCapability.swift` maps entitlement requests to App Store Connect capability types. Limit version 1 to a proven subset and fail on unknown requested entitlements.

Build one validation operation that enforces the full checklist in this handover before any signer is invoked. Do not spread profile authorization checks across API, packaging, and signing code paths.

### Pseudo-Signing Code To Exclude

The exact xtool pseudo-signing dependency chain is:

1. `Sources/XToolSupport/DevCommand.swift:80-102` loads source entitlements and invokes the signer with `.adhoc`, printing `Pseudo-signing...`.
2. `Sources/XKit/DeveloperServices/App IDs/DeveloperServicesAddAppOperation.swift:172-189` later calls `signer.analyze(executable:)` to recover those entitlements.
3. `Sources/XKit/Signer/AutoSigner.swift:45-97` provisions, rewrites bundle IDs, embeds profiles, and invokes the real signer.
4. `Sources/XKit/Signer/SignerImpl.swift:94-111` represents ad-hoc signing with zero-length certificate/key input.

The replacement is explicit data flow:

```text
source entitlement plist
-> typed requested-entitlement model
-> capability/profile reconciliation
-> final entitlement model
-> one real signing operation
```

Also exclude the current Zupersign adapter:

- `SignerImpl.swift:149-163` deliberately filters the entitlement map to the root app due to an acknowledged signer limitation.
- The checked-out dependency bridge at `.build/checkouts/zsign/Sources/Zupersign/signer.cpp:22-80` ignores per-path mappings and applies one entitlement payload broadly.
- `Package.swift:25` and lines 71-72 connect the zsign and `SignerSupport` dependencies.

Do not preserve Zupersign as a compatibility fallback. A missing or failed validated signing kernel is a fatal, actionable error.

### `apple-codesign` And `rcodesign`

Primary upstream references:

- Repository: <https://github.com/indygreg/apple-platform-rs>
- Crate source: <https://github.com/indygreg/apple-platform-rs/tree/main/apple-codesign>
- Rust API documentation: <https://docs.rs/apple-codesign/latest/apple_codesign/>
- End-user documentation: <https://gregoryszorc.com/docs/apple-codesign/main/>
- Known quirks: <https://gregoryszorc.com/docs/apple-codesign/main/apple_codesign_quirks.html>
- IPA support tracking: <https://github.com/indygreg/apple-platform-rs/issues/30>
- Distribution timestamp rejection context: <https://github.com/indygreg/apple-platform-rs/issues/56>

Source areas to inspect after pinning a revision:

- `apple-codesign/src/bundle_signing.rs` for nested bundle discovery, scoped settings, signing order, and resource sealing.
- `apple-codesign/src/code_resources.rs` for `CodeResources` rule generation and nested-code seals.
- `apple-codesign/src/macho_signing.rs` and `macho_universal.rs` for signature allocation and thin/fat Mach-O handling.
- `apple-codesign/src/embedded_signature_builder.rs` for CodeDirectory, special slots, CMS, and signature sizing.
- `apple-codesign/src/entitlements.rs` and `plist_der.rs` for XML and DER entitlement slots.
- `apple-codesign/src/cryptography.rs` and `apple_certificates.rs` for CMS and Apple certificate-chain handling.
- `apple-codesign/src/verify.rs` for available checks and explicit verification gaps.
- `apple-codesign/src/cli/config.rs` for scoped signing settings and timestamp control.

The project must supply all iOS-specific policy around this kernel: provisioning-profile parsing and embedding, entitlement authorization, per-bundle profile selection, IPA layout, distribution timestamp disabling, and post-sign validation. `rcodesign verify` is not equivalent to Apple's execution or App Store validation policy.

Before adopting a revision:

1. Record source commit, crate version, license, binary checksum, Rust toolchain, and enabled features.
2. Sign the minimal app and inspect every signature slot.
3. Compare against a known-good Xcode distribution artifact.
4. Verify on macOS with `codesign --verify --strict` during qualification.
5. Upload the exact artifact and wait for completed App Store processing.
6. Install it through TestFlight.

### IPA Packaging And Release Manifest

xtool's IPA output is only a layout reference:

- `Sources/XToolSupport/DevCommand.swift:142-171` places the built app under `Payload` and invokes a ZIP compressor.
- `Sources/XToolSupport/ProcessZIPCompressor.swift:9-30` wraps system `zip` and `unzip` tools.
- `Sources/XKit/Utilities/ZIPCompressor.swift` defines the injectable compression boundary.

The new packer must additionally preserve executable modes and symlinks, reject paths outside `Payload`, generate deterministic file ordering and normalized metadata where compatible, and verify the final ZIP by re-reading it. The distribution profile must already be embedded and all nested code must already be signed before ZIP creation.

Use `~/.config/opencode/skills/appstore-release/scripts/release.sh:1061-1081` as the initial manifest field reference. Its `write_release_manifest()` records the IPA checksum and resolved App Store Connect build. Improve it by using relative artifact paths where possible, recording Build Upload identity and complete toolchain provenance, and never relying on a stale absolute path.

### USB Pairing, Device Discovery, Installation, And Launch

Classic device-operation references:

- `Sources/XKit/Installation/Connection.swift:21-186` provides an actor-based connection and pooling model.
- `Sources/XKit/Installation/ConnectionManager.swift:48-346` merges usbmux and libimobiledevice discovery and caches wireless-lockdown hints.
- `Sources/XKit/Installation/IPAUploader.swift:19-85` uploads an IPA through AFC to `/PublicStaging`.
- `Sources/XKit/Installation/IPAInstaller.swift:12-27` invokes `installation_proxy` installation.
- `Sources/XKit/Installation/AppInstaller.swift:92-203` coordinates progress, timeout, retry, and post-install verification.
- `Sources/XKit/Installation/DDIMounter.swift` is compiled out and contains a Linux failure path. Do not make it a version 1 dependency.

The first modern wireless implementation should use the Python bridge rather than porting CoreDevice protocols immediately:

- `Sources/XKit/Integration/PyMobileDevice3NetworkBridge.swift:9-90` writes and runs a temporary Python helper with timeout handling.
- `PyMobileDevice3NetworkBridge.swift:92-493` contains the generated Python implementation.
- Lines 102-117 import the exact `pymobiledevice3` modules used for USB bootstrap, remote pairing, tunnels, installation, and launch.
- Lines 152-239 attempt CoreDevice bootstrap from USB and create remote pairing records.
- Lines 241-346 build and score remote-pairing candidates through mDNS and saved records.
- Lines 356-478 establish the tunnel, install through `InstallationProxyService`, and launch through `AppServiceService`.
- Lines 136-149 and 403-445 contain Termux-specific path, UID, and IPv6 route hacks. Generalize or remove these for standard Linux.
- `Sources/XKit/Integration/IntegratedInstaller.swift:303-445` shows where native installation falls back to this bridge.
- `Sources/XToolSupport/DevCommand.swift:1390-1700` shows full build/install/launch orchestration, but should not be copied as one command.

Relevant pinned `pymobiledevice3` modules to inspect directly:

- `pymobiledevice3/lockdown.py` for usbmux lockdown creation.
- `pymobiledevice3/bonjour.py` for `_remotepairing._tcp.local` browsing.
- `pymobiledevice3/pair_records.py` for pairing-record persistence.
- `pymobiledevice3/remote/tunnel_service.py` for CoreDevice tunnel and remote-pairing services.
- `pymobiledevice3/remote/remote_service_discovery.py` for RSD connections.
- `pymobiledevice3/remote/core_device/app_service.py` for application launch.
- `pymobiledevice3/services/installation_proxy.py` for local IPA installation.
- `pymobiledevice3/tunneld/` for the existing long-running tunnel daemon architecture.

Operational evidence is in `~/environments/external/xtool/THREE_DEVICE_TERMUX_IOS_HANDOFF.md`:

- Lines 14-18 state that unplugged wireless deploy and launch were validated under a privileged Android context.
- Lines 20-36 contain the canonical pair, cleanup, and run flow.
- Lines 38-50 record success markers and intermittent installation timeouts.
- Lines 72-76 identify bridge bootstrap, timeout, and privileged tunnel behavior that must be preserved until replaced.

Version 1 must own helper lifecycle: process group, timeout, cancellation, route cleanup, temporary files, and stale-state detection. Requiring operators to run `pkill` is not acceptable.

### App Store Connect Build Upload And TestFlight Polling

The authoritative local schema is `~/environments/external/App-Store-Connect-OpenAPI-Spec/specs/latest.json` at the snapshot recorded above.

Key path and schema ranges:

- `/v1/buildUploadFiles`, lines 28226-28316.
- `/v1/buildUploadFiles/{id}`, lines 28317-28523.
- `/v1/buildUploads`, lines 28524-28614.
- `/v1/buildUploads/{id}`, line 28615 onward.
- `/v1/buildUploads/{id}/buildUploadFiles`, line 112926 onward.
- `BuildUploadFile`, line 187972 onward, and `BuildUploadFileResponse`, line 188063 onward.
- `BuildUploadFileCreateRequest`, line 188079 onward, and `BuildUploadFileUpdateRequest`, line 188176 onward.
- `BuildUpload`, line 188216 onward, and `BuildUploadResponse`, line 188433 onward.
- `BuildUploadCreateRequest`, line 188469 onward.
- `BuildUploadState`, lines 236975 onward.
- `Checksums`, line 237128 onward.
- `DeliveryFileUploadOperation`, lines 237517 onward.

xtool's checked-in generated client is not sufficient for this phase. `~/environments/external/xtool/Sources/DeveloperAPI/openapi-generator-config.yaml:1-12` filters generation to provisioning-related tags and omits Build Upload operations. Generate a narrow project-owned client from the pinned full specification or implement these operations explicitly; do not assume the existing `DeveloperAPI` target exposes them. The current appstore-release API reference documents `altool`, so the pinned OpenAPI schema is authoritative for binary upload.

Gate 2 implemented this project-owned client in `ASCKit` (`Sources/ASCKit/BuildUpload.swift`,
`Sources/ASCKit/BuildUploader.swift`). The implementation sequence derived from those
schemas is now implemented as follows:

1. `POST /v1/buildUploads` with app relationship, platform, `cfBundleShortVersionString`, and `cfBundleVersion`.
2. `POST /v1/buildUploadFiles` with build-upload relationship, filename, file size, `assetType=ASSET`, and `uti=com.apple.ipa`.
3. Execute every returned `DeliveryFileUploadOperation` using its method, URL, required headers, offset, length, part number, and expiration.
4. Persist returned entity tags when the schema or operation requires them.
5. `PATCH /v1/buildUploadFiles/{id}` with source checksums and `uploaded=true`.
6. Poll the Build Upload state through `AWAITING_UPLOAD`, `PROCESSING`, and terminal `COMPLETE` or `FAILED`.
7. Resolve the exact resulting build by app, marketing version, and build number.
8. Poll build processing and `buildBetaDetail` until internal TestFlight readiness or a terminal failure.

Portable release-script references:

- `release.sh:478-499`, `release_build_number()`, computes the next integer build number.
- `release.sh:501-520`, exact number lookup and duplicate rejection, prevents re-uploading an existing build.
- `release.sh:522-610`, source and packaged build-number checks plus synchronized plist preparation.
- `release.sh:1022-1034`, local IPA version check before Apple's macOS-only validation command. Adapt the local check, not `xcrun altool`.
- `release.sh:1036-1059`, upload identity bookkeeping around `altool`. Replace transport completely with Build Upload resources.
- `release.sh:1061-1081`, release manifest writing.
- `release.sh:1083-1151`, bounded processing and beta-state polling.
- `~/.config/opencode/skills/appstore-release/references/asc-api.md:60-71` documents build lookup and beta-state semantics.

Do not adapt `release.sh:894-998` (`xcodebuild archive` and export) or its Keychain/Xcode profile-installation mechanics. The new bundle assembler, profile manager, signing kernel, and IPA packer replace those phases.

### Representative Existing Project Shapes

These local projects are useful private references for fixtures and failure modes. Do not copy credentials, profiles, release logs, operational identifiers, or production bundle IDs into this repository.

| Project | Useful reference | Lesson |
| --- | --- | --- |
| `~/environments/personal/pus/stupid-social` | `Package.swift`, `xtool.yml`, `Info.plist`, `.release/release-manifest.json` | Best simple extension-free project shape and release-manifest comparison candidate |
| `~/environments/personal/pus/stupid-authenticator` | `xtool.yml`, app/extension entitlements, `docs/implementation-notes.md:23-38` | Future per-bundle profile, capability, entitlement, and versioning requirements |
| `~/environments/personal/pus/stupid-widgets/stupid-widgets` | `xtool.yml`, widget entitlements, extension plist and metadata | Unsupported Apple build-tool outputs such as App Intents metadata and extension packaging |
| `~/environments/personal/pus/stupid-torrent-client` | `scripts/release.sh`, `.env.example`, simple package shape | Earlier release-script evolution; treat its checked-in script as a prototype, not the canonical reference |

Known-good Xcode-produced release artifacts may be used locally for differential signature inspection, but they are secret-bearing operational data. Never add them to fixtures. Create sanitized synthetic certificate/profile/signature fixtures for committed tests.

### Reuse Summary

Strong adaptation candidates:

- xtool's SwiftPM planner and synthetic executable packer.
- xtool's Xcode-app SDK selection logic and Swift SDK artifact structure.
- xtool's ASC JWT generator and generated public API models.
- xtool's RSA key and certificate parsing primitives after modern validation is added.
- The release script's distribution certificate/profile, exact build-number, polling, and manifest concepts.
- The xtool `pymobiledevice3` bridge as the first wireless protocol integration.
- `apple-codesign` as a pinned signing kernel after the TestFlight proof gate.

Code paths to exclude:

- xtool's password, anisette, GrandSlam, and private Developer Services authentication.
- xtool's `XTL-*` identifier rewriting.
- xtool's pseudo-signing and Zupersign adapter.
- xtool's monolithic development command.
- Xcode project generation, `xcodebuild`, Keychain, `altool`, and Transporter flows.
- macOS simulator, `simctl`, `devicectl`, and LLDB paths.
- Silent copying of resource formats that require unavailable Apple compilers.

## Legal And Distribution Constraint

The current Xcode and Apple SDK agreement appears to restrict Apple SDK execution and use to Apple-branded hardware running macOS. User-provided SDK export avoids redistribution but does not necessarily authorize using the SDK on Linux hardware.

This is a project-level legal gate:

- Do not represent the approach as licensed or approved by Apple without qualified review.
- Do not distribute Apple SDK files or derived bundles.
- Keep the SDK exporter and importer separable from project releases.
- Document the relevant agreement version and user responsibility before any public release.

This document records an engineering concern, not legal advice.

## Ordered Implementation Gates

### Gate 0: SDK And Compiler Proof

- Define the SDK import manifest and archive format.
- Export a device-only SDK from Xcode.
- Import it on a clean Linux host.
- Compile and link minimal Swift, Foundation, and SwiftUI fixtures.
- Inspect Mach-O architecture, deployment target, SDK version, runtime paths, and absolute-path leakage.
- Record the validated host Swift and Xcode SDK pair.

Status: **complete** on the isolated WSL host. The exporter, import format, and importer
are implemented in this repository (`stupid-app sdk export`, `docs/sdk-export-format.md`,
`stupid-app sdk import`). A minimal SwiftUI app built and linked to `Mach-O 64-bit arm64`
with a valid `LC_BUILD_VERSION`. Details, archive checksum, and fixture commands are in
`docs/implementation-notes.md`.

Validated pair: Xcode 26.1.1 (build 17B100), iPhoneOS SDK 26.1, toolchain Swift 6.2.1,
host Swift 6.2.4 on x86_64 Ubuntu 24.04.

Known link-time caveat: Linux clang defaults the SDK version in `LC_BUILD_VERSION` to the
deployment target because it does not read `SDKSettings.json`. The planner/packer must
inject the real SDK version via `-platform_version` linker flags (verified: explicit
`-platform_version ios 17.0 26.1` yields `sdk=26.1.0`).

Exit condition: a clean Linux host reproducibly builds an unsigned minimal SwiftUI app.

### Gate 1: Distribution Signing Proof

- Register a disposable explicit bundle ID through the public API.
- Create or import an Apple Distribution identity.
- Create and validate an iOS App Store profile.
- Assemble a minimal unsigned app.
- Sign it once with the candidate `rcodesign` revision and timestamps disabled.
- Package the IPA.
- Verify signature, resources, profile, and entitlements independently.

Status: **complete** on the isolated WSL host. `stupid-app new`, `stupid-app build`,
`stupid-app credentials add`, `stupid-app signing setup --kind distribution`, and
`stupid-app release archive` are implemented in this repository. The registered
disposable bundle ID `<disposable-bundle-id>` was provisioned with a real App
Store profile, an existing Apple Distribution identity was imported (the team already
had active distribution certificates, so minting was blocked by Apple's limit), and a
distribution IPA was built, signed once with the pinned `rcodesign` 0.29.0 binary
(timestamps disabled), and packaged. Independent checks confirmed the ARM64 Mach-O,
CodeDirectory/CMS/entitlements slots, zero provisioned devices, the embedded profile
matching the downloaded App Store profile, and `codesign --verify --strict` passing on
macOS for the Linux-produced signature. Details and exact commands are in
`docs/implementation-notes.md`.

Signer pin: `docs/rcodesign-pin.md`. The imported identity, profile, and bundle ID
remain live team resources; the bundle ID is disposable and can be removed after the
proof.

Exit condition: local checks pass and the exact signed artifact is ready for upload.

### Gate 2: Linux Build Upload Proof

- Implement the minimal JWT and Build Upload API client.
- Upload the distribution-signed proof IPA.
- Persist the public-safe upload/build outcome in the release manifest.
- Poll to a terminal Build Upload state.
- Resolve and poll the resulting build.
- Install the processed build through TestFlight.

Status: **complete** on the isolated WSL host. The Build Upload client and
`BuildUploader` orchestration live in `ASCKit` (`Sources/ASCKit/BuildUpload.swift`,
`Sources/ASCKit/BuildUploader.swift`, `Sources/ASCKit/ReleaseManifest.swift`), and
`stupid-app release upload [--wait]` is wired into the CLI
(`Sources/stupid-app/ReleaseUploadCommand.swift`). A live upload on the isolated WSL
host proved creation, file reservation, delivery, checksum commit, terminal-state
polling, exact-build resolution, and beta-state polling. The accepted build used a
native catalog with compressed `bvx2` payloads and `actool`-matching nested icon-name
metadata. App Store Connect reported `processing=VALID` and
`internal=READY_FOR_BETA_TESTING`; the release manifest was written, and the same build
installed and launched through TestFlight.

Exit condition: App Store Connect reports `VALID`, internal TestFlight becomes ready,
and the app launches from TestFlight.

### Live Gate 2 Upload Findings

A real distribution-signed IPA for a proof app was uploaded from the isolated WSL host
with `stupid-app release upload --wait`. The upload transport worked end-to-end; App
Store Connect's build-upload validation then rejected the app and emailed the
diagnostics below. Treat these as authoritative packaging requirements for Gate 2 and
Gate 5.

#### 1. Build-system Info.plist keys (resolved)

App Store validation requires the Xcode build-system keys that the Linux packer was not
emitting. The merged `Info.plist` in the IPA must carry, at minimum:

- `DTPlatformName` = `iphoneos`
- `DTPlatformVersion` = the real iPhoneOS SDK version (e.g. `26.1`)
- `DTSDKName` = `iphoneos26.1`
- `DTXcode` = numeric Xcode version (e.g. `2611` for 26.1.1)
- `DTXcodeBuild` = Xcode build (e.g. `17B100`)
- `DTCompiler` = `com.apple.compilers.llvm.clang.1_0`
- `BuildMachineOSBuild` must be absent (never invent a macOS build number on Linux)

These are now injected by the packer from the SDK export manifest
(`Packer.injectBuildSystemKeys`), and the `BuildMachineOSBuild` key is explicitly
removed. Without `DTPlatformName` the app is rejected with `ITMS-90507`; the SDK/Xcode
version rejection (`ITMS-90534`) followed from the missing platform identification.
Orientation keys were also corrected to the iPad-required set
(`UISupportedInterfaceOrientations~ipad`).

#### 2. App icon asset catalog (resolved)

The app icon was the remaining blocker. App Store validation for an iOS 11+ SDK build
rejects the old icon approach with:

- `ITMS-90022` / `ITMS-90023` — no 120x120 (iPhone) and 152x152 (iPad) app icon
  resolvable in the bundle.
- `ITMS-90713` — no `Assets.car` (compiled asset catalog); "apps built with iOS 11 or
  later SDK must supply app icons in an asset catalog and must also provide a value for
  this Info.plist key" (`CFBundleIconName`).

Key findings:

- **Concrete PNGs plus `CFBundleIconName`/`CFBundleIcons` are not enough.** The packer
  generates the full `Icon-*.png` set natively (pure-Swift `swift-png`, no external
  image tools) and sets `CFBundleIconName`, `CFBundleIcons`, and `CFBundleIcons~ipad`,
  but App Store Connect still cannot resolve an app icon because the icons must live in
  a compiled `Assets.car`.
- **The compiled catalog is normally produced only by `actool`**, which runs only on
  macOS (it depends on CoreUI). Xcode-produced IPAs embed `Assets.car` plus the loose
  PNGs; that is why they pass. xtool's Linux-built `.app` bundles contain the loose
  PNGs and an uncompiled `Assets.xcassets` but no `Assets.car`, and there is no
  evidence the xtool Linux icon path was ever App Store-validated.
- **The `.car` format is a `BOMStore` container** (NeXTSTEP bill-of-materials binary)
  holding CoreUI blocks (`CARHEADER`, `EXTENDED_METADATA`, `KEYFORMAT`) and B-tree
  databases (`FACETKEYS`, `RENDITIONS`, `APPEARANCEKEYS`, `BITMAPKEYS`), with
  per-rendition `csiheader`/TLV/pixel-rendition payloads. The format is documented by
  reverse-engineering work (dbg.re's `.car` deep dive, Timac's `.car` format
  write-up, `bomutils`' `bom.h`). No maintained cross-platform `.car` *writer* was
  found; readers exist.

**Current implementation:** a native `Assets.car` writer for the app-icon subset is implemented in
`Sources/BuildCore/AssetCatalogWriter.swift` (`AssetCatalogWriter`). It builds the
full BOMStore container and CoreUI blocks/trees from the format documentation
(clean-room, no GPL `darling` code), and the packer generates `Assets.car`
automatically during `stupid-app build` / `stupid-app release archive`. Pixel payloads
use Apple's BSD-3-Clause LZFSE reference implementation pinned at commit
`e634ca58b4821d9f3d560cdc6df5dec02ffc93fd`; the vendored source and license notice are
in `Sources/CLZFSE` and `THIRD_PARTY_NOTICES.md`.

Two additional live uploads establish that local CoreUI acceptance is not sufficient:

- An `MLEC` compression-type-0 catalog with raw ARGB pixels passed `assetutil --info`,
  `--validate-file`, and thinning, but App Store validation returned the same three
  icon errors.
- A type-4 `MLEC` catalog with the exact four `KCBC` row chunks used by `actool` and
  valid raw (`bvx-`) LZFSE streams reported `Compression: lzfse` in `assetutil` and
  passed all local validation, but App Store validation again returned the same errors.
- Differential inspection against the `actool` golden catalog shows matching named
  blocks, trees, rendition keys, facet metadata, phone/iPad multisize records, and
  `assetutil` output. The material payload difference is that `actool` emits genuinely
  compressed LZFSE v2 (`bvx2`) streams.

The accepted sequence established two additional requirements. Genuinely compressed
`bvx2` payloads alone still failed when only the top-level `CFBundleIconName` was
present. Matching `actool` by also writing `CFBundleIconName=AppIcon` inside both the
phone and iPad `CFBundlePrimaryIcon` dictionaries cleared icon validation. The exact
Linux-produced catalog passed macOS `assetutil --validate-file`, every generated KCBC
chunk round-trips to its source ARGB rows in tests, and App Store Connect accepted the
combined output. A proof build without `ITSAppUsesNonExemptEncryption` then reached
`MISSING_EXPORT_COMPLIANCE`; declaring `false` for the encryption-free fixture allowed
the next build to become internally TestFlight-ready.

### Gate 3: Development Signing Proof

- Register a physical device.
- Create or import an Apple Development identity.
- Create a device development profile.
- Reconcile development entitlements.
- Sign once, package, and install over USB.

Status: **complete** on the isolated WSL host. `devices`,
`signing setup --kind development`, `run --usb`, development identity/profile storage,
the reusable `SigningPipeline`, and the `DeviceKit` `pymobiledevice3` adapter are
implemented. A physical device was registered; a development identity/profile was
created; USB pass-through and pairing were validated; and the app was built, signed
once, packaged, installed, and launched. Installation required a qualified
`usbmuxd` 1.1.1 build with `USB_MTU=16383` to preserve frame boundaries through WSL
USBIP. iOS 26.6 launch used pinned `pymobiledevice3` 8.2.1 to create a privileged
USB CoreDevice tunnel and returned a live process token.

`run --usb` now has bounded output, timeout/cancellation checks, Linux process-group
cleanup, explicit install/launch timeouts, JSON device-list parsing, explicit usbmux
socket propagation, and developer-package installation. Its current direct DVT launch
subcommand is not valid on iOS 26.6; integrating the proven CoreDevice launch helper,
privilege boundary, pinned Python environment, patched-usbmuxd provisioning, and helper
lifecycle belongs to Gate 4 rather than being hidden behind implicit privilege
escalation.

Exit condition: the app launches on the registered device with a valid development signature.

### Gate 4: Wireless Transport Proof

- Pair once over USB on a same-LAN Linux host.
- Discover the paired device over the network.
- Establish the required CoreDevice connection or tunnel.
- Install and launch the development-signed IPA.
- Repeat without stale helper cleanup.

Exit condition: three consecutive unplugged install-and-launch runs pass.

### Gate 5: Productize The CLI

- Create the package and command hierarchy.
- Implement project generation and typed configuration.
- Integrate the validated SDK, build, signing, device, and upload paths.
- Add structured diagnostics and secret redaction.
- Add compatibility and fixture tests.
- Document setup, SDK export, credentials, pairing, development, release, and recovery.

Exit condition: all acceptance criteria run through stable CLI commands on clean supported environments.

## Test Strategy

Required automated coverage:

- Project schema validation and generated project fixtures.
- SDK archive checksum, traversal, symlink, architecture, and atomic-install tests.
- Host Swift and SDK compatibility checks.
- SwiftPM plan and bundle assembly golden tests.
- Mach-O architecture and load-command inspection.
- Profile CMS parsing and malformed, expired, wrong-team, wrong-certificate, and wrong-bundle fixtures.
- Development and distribution entitlement derivation.
- Certificate and private-key matching.
- Signed CodeDirectory, CMS, XML/DER entitlement, and resource-seal verification.
- IPA path, mode, symlink, and deterministic packaging checks.
- JWT construction and renewal.
- Build Upload multipart operations, retries, offsets, headers, checksums, expiration, and failure states.
- Release-manifest identity and stale-artifact detection.
- Process timeout, cancellation, and cleanup for device helpers.

Required recurring integration coverage:

- Clean WSL x86_64 SDK import and SwiftUI build.
- Clean native Linux ARM64 path if later declared supported.
- Development signing and USB install on a physical iPhone.
- Wireless install and launch on a physical iPhone.
- Distribution signing and real TestFlight processing using a disposable build number.
- Independent macOS `codesign --verify --strict` comparison during signer qualification, even though macOS is not a production runtime dependency.

## Primary Risks

1. Apple SDK licensing may prevent compliant use on non-Apple hardware.
2. A third-party signer may produce structurally plausible output that App Store Connect rejects.
3. `rcodesign` does not provide an iOS provisioning or IPA workflow and its built-in verification is not Apple's full policy engine.
4. Swift compiler and Xcode SDK interfaces must remain compatible as versions change.
5. Linux lacks Apple's resource compilers, limiting the supported project model unless replacements are built. The native app-icon `.car` subset is App Store-validated; other Apple resource compilers (e.g. `momc`) remain out of scope.
6. Modern iPhone wireless protocols and Developer Disk Image behavior change across iOS versions.
7. WSL USB pass-through, mirrored-network mDNS, IPv6, and privileged CoreDevice tunnel behavior may prevent direct wireless deployment even though the Windows host is on the iPhone's LAN.
8. Apple Developer and App Store Connect API behavior, roles, certificate limits, and profile rules can change.
9. Signing keys inside WSL, virtual-disk exports, or a future VPS materially increase the credential-security burden.

## Open Decisions

- Final product, package, and executable name.
- First officially supported Linux architecture and distribution (x86_64 Ubuntu 24.04 is the validated proof pair).
- Exact first Swift/Xcode SDK compatibility pair (Xcode 26.1.1 / Swift 6.2.1 export, Swift 6.2.4 host is the validated proof pair).
- Whether `rcodesign` remains a pinned subprocess or becomes a directly integrated Rust component later.
- Whether owner-only plaintext credential storage remains acceptable beyond technical
  validation or is replaced by an OS keyring/HSM-backed design.
- Release directory layout and retention policy.
- Future local device gateway protocol and trust model.
- Minimum entitlement and capability set included in version 1.
- Whether the initial WSL x86_64 environment becomes a supported production host or remains a proof environment alongside a future native Linux host.
- Whether build and release environments are persistent or created ephemerally.

## Recommended Next Work

Proceed with Gate 4: integrate the proven USB CoreDevice bootstrap/launch path behind a
bounded helper lifecycle, provision and checksum the pinned `pymobiledevice3` environment
and USBIP-compatible usbmux transport, then prove three consecutive unplugged network
install-and-launch runs without manual cleanup. Gate 5 remains CLI productization.
