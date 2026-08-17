# Implementation Notes

## Purpose And Rules

This file is the chronological, public-safe engineering log. Append a dated entry after meaningful implementation, investigation, verification, release, or architectural work.

Each entry should record:

- What changed.
- Why it changed.
- Decisions made.
- Verification performed and its result.
- Known limitations, failures, and follow-up work.

Do not include personal information, credentials, private keys, tokens, certificate contents, device identifiers, private hostnames, account identifiers, or secret-bearing command output. Use generic placeholders where operational context is necessary.

The current project plan and architecture live in `docs/engineering-handover.md`. Update that document when an implementation-note entry changes current truth.

## 2026-08-16 - Initial Scope And Architecture Research

### Summary

- Created `docs/engineering-handover.md` as the maintained source of truth for scope, architecture, proof gates, risks, and recommended next work.
- Created the root `AGENTS.md` with mandatory read-first, documentation-update, security, implementation, and verification rules for future engineering sessions.
- Created this public-safe chronological engineering log.
- Established the project goal: create, build, sign, wirelessly run, and release a SwiftPM/SwiftUI iOS application without Xcode or macOS during normal operation.
- Limited the first supported project model to one physical-device SwiftPM application with code-based SwiftUI.
- Required paid Apple Developer Program membership and public App Store Connect API authentication.
- Required real Apple Development and Apple Distribution signatures with no pseudo-signing or ad-hoc intermediate signing.
- Set successful App Store Connect processing and TestFlight installation as the release acceptance proof.
- Deferred Raspberry Pi execution and app-extension support.
- Selected a compatible Linux VPS as the initial build and release environment.

### Research Reviewed

- Reviewed xtool's project generator, Swift SDK builder, SwiftPM planner and packer, provisioning code, signer adapter, device installation code, and wireless `pymobiledevice3` bridge.
- Reviewed xtool's three-device Termux wireless handoff. It demonstrates unplugged network installation and launch but reports intermittent install timeouts and stale helper processes.
- Reviewed existing App Store release automation covering bundle registration, certificate and profile creation, Xcode archive/export, upload, TestFlight processing, beta metadata, and release manifests.
- Reviewed representative SwiftPM applications with simple app bundles and app extensions to understand real provisioning, entitlement, versioning, and packaging failures.
- Reviewed the App Store Connect OpenAPI Build Upload resources as a platform-neutral alternative to `altool` and Transporter.
- Reviewed `apple-platform-rs` and its `apple-codesign`/`rcodesign` implementation as a stronger signing foundation than xtool's current Zupersign adapter.

### Important Findings

- xtool can create and cross-compile a restricted SwiftPM iOS application on Linux by building a Swift SDK artifact from Xcode contents and using Linux `ld64.lld`.
- The current xtool SDK builder copies more platforms than the physical-device workflow needs and does not provide sufficient version, checksum, or compatibility validation.
- The inspected xtool checkout's documented XIP path is disabled in that checkout because its XIP dependency was removed. A Mac-side export from an installed `Xcode.app` is a cleaner project boundary.
- xtool pseudo-signs entitlement-bearing builds so provisioning can recover requested entitlements from the executable. Passing source entitlements directly removes the reason for this pass.
- xtool's final development install does use a real certificate, but its current provisioning flow is development-only, rewrites bundle identifiers, and has an acknowledged per-extension entitlement-signing defect.
- xtool does not implement distribution profiles, distribution archives, App Store IPA export, or App Store Connect binary upload.
- Existing release automation delegates archive, signing, and export correctness to Xcode. Its certificate, profile, build-number, API, polling, and release-manifest concepts are portable.
- An `.xcarchive` is not required to upload a correctly constructed and distribution-signed IPA.
- `apple-codesign` supports cross-platform Mach-O and bundle signing, CMS, nested code, resource sealing, and XML/DER entitlements, but it does not provide iOS profile selection, entitlement reconciliation, or IPA construction.
- iOS distribution signing through `rcodesign` must disable timestamping. Real App Store processing remains the decisive compatibility test.
- App Store Connect exposes Build Upload and Build Upload File APIs suitable for direct Linux upload.
- A typical public VPS cannot directly discover an iPhone on a home LAN. Wireless deployment requires a same-LAN Linux host or a future local gateway.
- The available low-resource Raspberry Pi is unsuitable as a local Swift compiler host. It may later serve as a lightweight device gateway.
- The current Apple SDK license appears to create a legal gate for using Apple SDK contents on non-Apple hardware even when users export their own bundle.

### Decisions Recorded

- Use `docs/engineering-handover.md` as the current engineering source of truth.
- Use this file as the chronological implementation and investigation log.
- Start with technical proof gates before building the complete CLI.
- Adapt xtool's planner and packer design rather than its monolithic development command.
- Use direct source entitlement input and exactly one real signing pass.
- Evaluate a pinned `rcodesign` revision as the first signing kernel; do not add Zupersign as a fallback.
- Use public App Store Connect APIs and reject private Apple authentication fallbacks.
- Produce an IPA and immutable release manifest rather than requiring an `.xcarchive`.
- Keep unsupported Apple resource formats outside the initial project model and fail loudly when encountered.

### Verification

- Repository inspection and documentation research were completed.
- The initial workspace contained no source files or prior documentation.
- No SDK extraction, Linux iOS build, signing, device deployment, or App Store upload has been performed in this repository yet.

### Next Work

- Define the versioned SDK import manifest and archive layout.
- Implement or prototype a Mac-side iPhoneOS-only SDK exporter.
- Import the SDK on a clean Linux ARM64 host and compile minimal Swift, Foundation, and SwiftUI fixtures.
- Record the validated Swift compiler, Xcode build, iPhoneOS SDK, Linux distribution, linker tools, and artifact hashes.
- Update the engineering handover with results before proceeding to signing proofs.

## 2026-08-16 - Detailed Implementation Reference Index

### Summary

- Expanded `docs/engineering-handover.md` with a source-level implementation reference index intended to prevent future engineers from repeating the initial codebase survey.
- Recorded exact source snapshots for xtool, the App Store Connect OpenAPI specification, and the locally inspected `pymobiledevice3` package.
- Added gate-to-source mapping, symbol and line-range references, dependency boundaries, adaptation guidance, known defects, and explicit code paths that must not be copied.

### Areas Indexed

- CLI registration, signal handling, process cancellation, and tool lookup.
- Xcode SDK selection, Swift SDK artifact generation, Darwin tool installation, and Linux SDK registration.
- Project generation, YAML schema validation, SwiftPM graph planning, synthetic executable construction, and unsigned app assembly.
- App Store Connect JWT generation and public API boundaries.
- RSA key generation, certificate creation and parsing, credential storage, device registration, bundle-ID registration, profiles, capabilities, and entitlements.
- The exact xtool pseudo-signing chain and Zupersign integration that the new project must exclude.
- `apple-codesign` source areas and proof requirements for adopting a pinned `rcodesign` revision.
- IPA packaging and release-manifest references.
- USB pairing, modern CoreDevice remote pairing, tunnel, installation, launch, and helper-process lifecycle.
- App Store Connect Build Upload schemas, upload operations, exact-build resolution, processing polling, and TestFlight readiness.
- The existing xtool generated OpenAPI client omits Build Upload tags, so this project must generate a narrow client from the full pinned schema or implement those operations directly.
- Existing project shapes that can inform private local comparisons without becoming committed fixtures.

### Decisions And Caveats

- Line ranges are anchored to recorded source commits and must be refreshed when upstream snapshots change.
- Named symbols are authoritative when formatting or upstream edits move lines.
- The local `pymobiledevice3` installation is only a research reference; implementation must pin and verify its own distribution.
- `apple-platform-rs` is not yet checked out locally. Gate 1 must begin by pinning source in an ignored third-party directory and recording its revision and license.
- Existing release artifacts are operationally sensitive and must not be committed as test fixtures. Tests require sanitized synthetic profiles, certificates, signatures, and API responses.

### Verification

- Confirmed the referenced xtool commit and App Store Connect specification commit from their local Git repositories.
- Confirmed the locally inspected `pymobiledevice3` package version.
- Read the referenced SDK builder, project generator, planner, packer, process helper, JWT, key, certificate, certificate-operation, profile-operation, signing, release-script, wireless-bridge, and Build Upload schema sources.
- Searched the updated documentation for private absolute user paths and operational identifiers; none were intentionally added.

## 2026-08-16 - Isolated WSL Gate 0 Host

### Summary

- Replaced the immediate VPS plan with an isolated local WSL 2 test environment on an existing Windows development machine.
- Created a new WSL distribution named `iosdev-ubuntu` without modifying the existing Ubuntu or Docker distributions.
- Installed Ubuntu 24.04.4 LTS, an unprivileged default user, native build prerequisites, Swiftly 1.1.2, and Swift 6.2.4.
- Exported the configured distribution as a reusable compressed WSL base image outside the repository.

### Environment

- WSL 2 version 2.7.11.0 with kernel 6.18.33.2.
- x86_64 Ubuntu 24.04.4 LTS.
- Swift 6.2.4 targeting `x86_64-unknown-linux-gnu`.
- Approximately 31 GB RAM and 8 GB swap exposed inside WSL.
- Mirrored WSL networking was already enabled.
- The sparse filesystem had ample capacity for Swift, SDK, module-cache, and project experiments.

### Installation And Security

- Installed standard build dependencies through Ubuntu packages, including Clang, CMake, Ninja, Git, Curl, OpenSSL, ICU, XML, SQLite, Python, ZIP tools, and build-essential.
- Downloaded the pinned Swiftly 1.1.2 x86_64 archive and detached signature from swift.org.
- Imported the public swift.org key set and verified the Swiftly archive signature before extraction.
- Swiftly reported successful signature verification while installing Swift 6.2.4.
- No Apple SDK, App Store Connect credential, certificate, profile, pairing record, or project signing key was added to the image.

### Verification

- `swift --version` reported Swift 6.2.4 with target `x86_64-unknown-linux-gnu`.
- `swiftly list` reported Swift 6.2.4 as installed, active, and default.
- `swift -e 'print("SWIFT_WSL_OK")'` completed successfully.
- A fresh executable package created with `swift package init` built in 1.54 seconds and printed `Hello, world!`.
- After terminating and exporting the distribution, restarting it still ran the installed Swift toolchain and smoke executable successfully.

### Reusable Image

- Image path: `C:\WSL\images\iosdev-ubuntu-base-20260816.tar.gz`.
- Compressed size: approximately 2 GB.
- SHA-256: `5EB146BDF52F27C22881C5F61D544836571F02EB1A0E001534CAE27E69428ED8`.
- The checksum applies only to this base export and must be updated after re-exporting a changed image.

### Limitations And Follow-Up

- Native Linux Swift compilation is proven; iOS cross-compilation is not yet proven because the iPhoneOS Swift SDK has not been exported or imported.
- `usbipd-win` is not installed, so USB trust, pairing, and device passthrough into WSL remain unverified.
- Mirrored networking is favorable for LAN testing, but iPhone mDNS discovery, CoreDevice tunneling, installation, and launch remain unverified.
- Gate 0 should continue by exporting an x86_64-host, iPhoneOS-only SDK bundle from Xcode and importing it into `iosdev-ubuntu`.

## 2026-08-16 - Gate 0: SDK Export, Linux Import, And SwiftUI Build Proof

### Summary

- Established the Swift package skeleton (`iosdev`) with a `SDKCore` library, a macOS-only
  `iosdev-sdk-export` executable, and a cross-platform `iosdev` CLI.
- Implemented and validated a versioned, checksummed, device-only iPhoneOS Swift SDK
  exporter (`iosdev-sdk-export`) against Xcode 26.1.1.
- Implemented a validating Linux importer (`iosdev sdk import`) that verifies the archive
  checksum, rejects unsafe archive entries, verifies every declared file checksum, checks
  host triple and Swift compiler compatibility, and registers with `swift sdk install`.
- Exported the SDK on macOS, transferred it to the isolated `iosdev-ubuntu` WSL host,
  imported it, and built and linked a minimal SwiftUI app for `arm64-apple-ios`.
- The linked executable is an ARM64 Mach-O (not ELF) with a valid `LC_BUILD_VERSION`.

### SDK Bundle Format

- Archive: `ios-dev-arm64-apple-ios-x86_64-unknown-linux-gnu.artifactbundle.tar.zst`
  (110 MB compressed).
- Layout documented in `docs/sdk-export-format.md`: `info.json`, `swift-sdk.json`
  (schema 4.0), `toolset.json`, `sdk-manifest.json`, `Developer/` payload, and a
  `toolset/bin` containing `ld64.lld`, `libtool`, and `dsymutil`.
- The bundle carries one target triple (`arm64-apple-ios`) and one host triple
  (`x86_64-unknown-linux-gnu`).
- Device-only selection: the iPhoneOS SDK, device Swift runtime resources
  (`swift/iphoneos` including prebuilt modules), clang resources, and the platform
  `Developer/usr/lib` and Library directories. No simulator or macOS content.
- `sdk-manifest.json` records generator version, source Xcode version and build, iPhoneOS
  SDK version, toolchain Swift major/minor, host and target triples, the pinned Darwin
  toolset source and checksum, and a SHA-256 for every hashed file (9,723 files).

### Exported Artifact Provenance

- Source Xcode: `Xcode-26.1.1.app`, version 26.1.1, build 17B100.
- iPhoneOS SDK version: 26.1.
- Toolchain Swift: 6.2.1 (read from the toolchain's own `swiftc --version`).
- Pinned Darwin tools: `xtool-org/darwin-tools-linux-llvm` v1.0.1, archive SHA-256
  `58f567cbea08afb89aaee5ca0c2200e6c9fe7c014022fe380f0188e940d8d071`.
- Export archive SHA-256:
  `0cf455b9b7f364ce4f12b7075b07d83db27b65f105ba33ce2ad1cd46c279ceee`.

### Verified Import And Build

On the clean `iosdev-ubuntu` WSL host (Swift 6.2.4, x86_64-unknown-linux-gnu):

```bash
iosdev sdk import ios-dev-arm64-apple-ios-x86_64-unknown-linux-gnu.artifactbundle.tar.zst \
  --expected-sha256 0cf455b9b7f364ce4f12b7075b07d83db27b65f105ba33ce2ad1cd46c279ceee
swift sdk list   # -> ios-dev
```

- Import verified the archive checksum, extracted safely, verified all 9,723 declared
  file checksums, checked host triple and Swift compatibility, then installed via
  `swift sdk install`. Bundle registered as artifact ID `ios-dev`.
- Re-import of the same bundle fails loudly with a clear already-installed diagnostic
  rather than silently replacing.

Fixture build on WSL (executable SwiftUI target, deployment target iOS 17):

```bash
swift build --swift-sdk ios-dev
```

- Result: `Build complete`; `Gate0App` is `Mach-O 64-bit arm64 executable`,
  flags `NOUNDEFS|DYLDLINK|TWOLEVEL|PIE`.
- Object file verified as `Mach-O 64-bit arm64 object`.
- `LC_BUILD_VERSION platform=2 minos=17.0.0`; platform 2 is iOS.

### Findings And Decisions

- `swift build --swift-sdk` correctly wires `-sdk`, `-resource-dir`, and the toolset's
  `ld64.lld` via `-ld-path`, so no custom packer was needed for this proof.
- SwiftPM and the Linux clang default the SDK version in `LC_BUILD_VERSION` to the
  deployment target (17.0) instead of the SDK version (26.1) because the Linux clang does
  not read `SDKSettings.json`. Passing explicit linker flags
  `-Xlinker -platform_version -Xlinker ios -Xlinker 17.0 -Xlinker 26.1` produced
  `sdk=26.1.0`. This confirms the handover's flagged xtool weakness and the intended
  planner fix: the planner/packer must inject the real SDK version at link time.
- The importer shells out to the platform `tar`. Two defects were found and fixed:
  a pipe-buffer deadlock (drain stdout/stderr before `waitUntilExit`) and AppleDouble
  `._` entries produced by macOS bsdtar. The exporter now runs tar with
  `COPYFILE_DISABLE=1`, and the importer rejects `._` entries defensively.
- On non-macOS Foundation, URL networking types require `FoundationNetworking`, and
  `Process` does not resolve bare executable names via PATH; both were handled.

### Limitations And Follow-Up

- Gate 0 exit condition (clean Linux host reproducibly builds an unsigned minimal SwiftUI
  app) is met. Compilation and linking used the imported device-only SDK on the isolated
  WSL host.
- The WSL host gained the `zstd` package as a build prerequisite.
- The proof used a hand-authored SwiftPM package. The planner/packer synthesis (xtool
  `PackLib` adaptation) and the `-platform_version` injection remain for later gates.
- USB pairing, wireless deployment, signing, and release upload are untouched.

## 2026-08-16 - Product Naming And Single Executable

### Summary

- Decided the product and executable name: `stupid-app` (singular), and the
  project-level configuration filename `stupid-app.yml`.
- Folded the standalone macOS exporter executable into the CLI as the `sdk export`
  subcommand. The package now builds one executable, `stupid-app`, instead of two.

### Naming Decision

- Chose `stupid-app` over `iosdev` (the then-working name) and over `stupid-apps`.
- CLI precedent favors a singular noun root: `docker`, `flutter`, `pod`, `xcodebuild`.
  Tools that manage apps as a resource use `apps` as a subcommand, not the root
  (`heroku apps:create`). This CLI is project-scoped like `pod`/`flutter`, so a plural
  root added nothing.
- `stupid-app` also separates the tool from the WSL distribution name `iosdev-ubuntu`,
  which is an operational environment and remains unchanged.

### Single Executable

- Removed the `iosdev-sdk-export` target and its separate `@main`. The exporter body
  moved into the main target as `SDKExportCommand` (`stupid-app sdk export`), registered
  under the existing `sdk` command group next to `sdk import`.
- The exporter code already compiled on Linux (Foundation, `Process`,
  `FoundationNetworking`), so the single binary keeps a uniform command surface on every
  platform. `sdk export` fails loudly on a host without an installed Xcode, matching the
  "fail loudly" and one-time-Mac-export invariants.
- The bundle manifest `generator` string changed from `iosdev-sdk-export` to `stupid-app`.
  The manifest format version is unchanged and the importer does not depend on the
  generator string, so previously exported bundles remain importable.
- Updated the SDK bundle spec: the archive is `tar.zst` (documented as gzip previously),
  and archive/bundle naming uses the `<target-triple>-<host-triple>` form the exporter
  actually emits.

### Verification

- `swift build` succeeds; the linked binary is `stupid-app`.
- `swift test` passes all 5 SHA-256 tests.
- `stupid-app --help`, `stupid-app sdk --help`, and `stupid-app sdk export --help` show
  the expected surface: root, `sdk export`, and `sdk import`.

### Follow-Up

- `iosdev-ubuntu` remains the active WSL test host name; it is unrelated to the CLI name.

## 2026-08-16 - Gate 1: Distribution Signing Proof

### Summary

- Pinned `apple-codesign`/`rcodesign` 0.29.0 into the ignored `third-party/` directory
  and recorded the MPL-2.0 obligations and per-architecture checksums in
  `docs/rcodesign-pin.md`.
- Decided to provision `rcodesign` per host as a pinned **prebuilt release binary**
  (static musl ELF) rather than compiling on each host. This removes a Rust toolchain
  requirement from every supported host, including future ARM hosts. The source
  checkout remains in `third-party/` for auditability.
- Extended the CLI with typed project configuration (`stupid-app new`,
  `stupid-app.yml`), an unsigned `.app` planner/packer (`stupid-app build`) that injects
  the real SDK version into `LC_BUILD_VERSION`, an encrypted credential store
  (`stupid-app credentials add`), distribution signing setup
  (`stupid-app signing setup --kind distribution`), and distribution archive
  (`stupid-app release archive`).
- Registered a disposable bundle ID, imported an existing Apple Distribution identity,
  created an App Store provisioning profile, built a minimal app, signed it once with
  the pinned `rcodesign` (timestamps disabled), and packaged a distribution IPA on the
  isolated WSL host.
- Renamed the SDK artifact ID from `ios-dev` to `stupid-app-ios` to match the product.
  The previously exported bundle remains importable; existing WSL installs still
  register as `ios-dev` until re-exported/re-imported.

### Decisions

- **Signer sourcing:** prebuilt pinned binaries per target architecture, verified by
  SHA-256. No Rust on supported hosts. Rationale: Apple ships no Linux signing tooling,
  so a low-level signing kernel is required; prebuilt static binaries avoid adding a
  compiler toolchain everywhere, directly minimizing target-host dependencies.
- **Identity reuse:** the team already had active Apple Distribution certificates, so
  minting a new one was blocked by Apple's certificate limit (HTTP 409). The CLI
  therefore supports importing an existing identity (`--import-key --import-cert
  --cert-id`) and reused the existing distribution identity for the proof rather than
  minting a new certificate.
- **Credential storage:** encrypted at rest with AES-256-GCM using an HKDF-SHA256 key
  derived from a passphrase plus a random per-file salt; directory mode `0700`, secret
  files mode `0600`, atomic writes, secret-bearing files outside the repository.
- **Bundle ID display name:** the ASC `bundleIds` API rejects the bundle identifier as
  a resource name; a human-readable name is derived from the identifier.

### Verification

- `stupid-app new AcceptanceApp` scaffolds the supported project shape without Xcode.
- `stupid-app build` on WSL produced an unsigned `.app` with an ARM64 Mach-O executable
  reporting `ios min 17.0.0 sdk 26.1.0` (real SDK version, not the deployment target).
- Live ASC round-trip: bundle ID `<disposable-bundle-id>` registered; existing
  distribution identity imported; `IOS_APP_STORE` profile created and downloaded; the
  profile parses with zero provisioned devices (App Store shape) and the expected
  entitlements.
- `stupid-app release archive` on WSL produced `AcceptanceApp.ipa` with
  `Payload/AcceptanceApp.app` containing the executable, `Info.plist`,
  `_CodeSignature/CodeResources`, and `embedded.mobileprovision` (byte-for-byte the
  downloaded profile).
- Signature inspection (`rcodesign print-signature-info`) confirmed CodeDirectory,
  RequirementSet, Entitlements, DER Entitlements, and CMS slots; entitlement plist
  shows `application-identifier`, `com.apple.developer.team-identifier`, and
  `get-task-allow=false`; the CMS chain chains to the Apple Root CA with
  `signature_verifies: true`.
- Independent macOS check on the Linux-produced artifact:
  `codesign --verify --strict` reported "valid on disk" and "satisfies its Designated
  Requirement"; `codesign -d` confirmed identifier, team identifier, and `get-task-allow
  false`.
- Tests: 19 pass across SDKCore, ProjectCore, and SigningKit (SHA-256 vectors, config
  validation, CMS plist extraction from synthetic fixtures, entitlement derivation and
  rejection).

### Artifacts And Cleanup

- The signed IPA and the temporary identity/profile material used during the proof were
  deleted after verification. The registered bundle ID and App Store profile remain as
  team resources; the bundle ID is disposable and can be removed after the proof.

### Findings And Follow-Ups

- `codesign`'s `--verify --strict` on macOS is a strong independent check that a Linux
  `rcodesign` signature is structurally valid, but App Store Connect processing remains
  the decisive compatibility test (Gate 2).
- The packer's synthetic-package approach works unchanged on Linux; the real-SDK-version
  linker flag injection is verified end-to-end.
- App Store Connect still reports distribution certificate state as `null` for these
  resources; certificate validity is better judged by the profile being created and
  signature verification rather than that field.
- Next gate: Gate 2 (Linux Build Upload proof) — implement the Build Upload API flow,
  upload the Gate 1 IPA, resolve the exact build, poll processing, and install through
  TestFlight.

## 2026-08-16 - Gate 2: Build Upload Client And `release upload` Command

### Summary

- Implemented the App Store Connect Build Upload client in `ASCKit` directly from the
  pinned OpenAPI schemas: Build Upload creation, Build Upload File reservation,
  execution of every returned `DeliveryFileUploadOperation`, PATCH commit with source
  checksums, Build Upload state polling, exact-build resolution by app + marketing
  version + build number, and processing plus `buildBetaDetail` polling to internal
  TestFlight readiness.
- Added `stupid-app release upload [--wait]` which locates the distribution IPA, reads
  the packaged marketing version and build number, resolves the app record by bundle
  ID, rejects already-uploaded build numbers, uploads, and writes a public-safe release
  manifest.
- Added `Sources/ASCKit/ReleaseManifest.swift` and the manifest write in
  `ReleaseUploadCommand.swift` recording bundle ID, versions, IPA path and SHA-256,
  Build Upload ID, build ID, upload/processing/beta states, and toolchain provenance.
- Added a new `ASCKitTests` target with decoding, exact-build matching, checksum,
  beta-readiness state-transition, and manifest tests using only synthetic fixtures.

### Decisions

- **No third-party upload client:** the pinned OpenAPI schema is authoritative for
  binary upload (`altool`/Transporter are prohibited). The client is hand-written to
  keep HTTP status/error decoding explicit and credential-safe.
- **Checksum verification is mandatory:** source checksums are computed (MD5 for
  `composite`, MD5 or SHA-256 for `file` per the server-declared algorithm) and any
  declared expected values must match before the file is committed. MD5 is used only
  because App Store Connect mandates it for upload verification, not for security.
- **Presigned URLs are never logged:** delivery operations run through
  `ASCClient.rawRequest`, which adds no JWT and never prints the URL or headers
  because presigned URLs carry their capability.
- **Exact-build resolution matches the release script:** the build must match the
  build number AND resolve its `preReleaseVersion` relationship to an included
  marketing version equal to the packaged `CFBundleShortVersionString`. A generic
  latest-build query is never used.
- **Polling is separable and testable:** beta-readiness classification and checksum
  verification are pure functions with unit tests; poll delays and clock are injectable
  on `BuildUploader`.

### Verification

- `swift build` and `swift build -c release` succeed; all 35 unit tests pass across
  SDKCore, ProjectCore, SigningKit, and the new ASCKit suite.
- The command surface exposes `stupid-app release upload [--wait]` with `--ipa`,
  `--app-bundle-id`, `--credential-password`, `--home`, `--output`,
  `--poll-interval`, and provenance options.
- Tests cover: Build Upload and Build Upload File decoding (including nested upload
  state errors), exact-build matching with marketing-version reconciliation, MD5 and
  SHA-256 checksum computation and mismatch rejection, internal beta readiness
  transitions, and release-manifest round-tripping without secrets.

### Limitations And Follow-Up

- The live App Store Connect round-trip has not yet been executed on the isolated WSL
  host. The distribution identity, profile, and credentials were cleaned up after the
  Gate 1 proof and must be re-established or re-imported before uploading.
- `release status` and the `doctor`, `devices`, and `device` commands remain
  unimplemented.
- The release manifest is written on every upload; a "resume / persist raw outcomes"
  diagnostic companion file remains future work.

## 2026-08-16 - Gate 2 Live Upload: Transport Proven, Packaging Gaps Found

### Summary

- Re-established the WSL credential store, distribution identity, and App Store profile
  for a proof app (re-importing the existing Apple Distribution identity after Gate 1
  cleanup), downloaded the pinned `rcodesign` 0.29.0 x86_64 musl binary, and executed a
  real App Store Connect upload with `stupid-app release upload --wait`.
- The upload transport worked end-to-end: Build Upload creation, Build Upload File
  reservation, delivery-operation execution, commit with source checksums, and Build
  Upload state polling all reached App Store Connect correctly.
- App Store Connect's build-upload validation then rejected the packaged app and
  emailed diagnostics. Two packaging gaps were identified and one was fixed.

### Finding 1 (resolved): missing build-system Info.plist keys

- `ITMS-90507` (missing `DTPlatformName`) and `ITMS-90534` (unsupported SDK/Xcode
  version) were caused by the Linux packer not emitting the Xcode build-system keys.
- Fixed `Packer.injectBuildSystemKeys`: the merged Info.plist now carries
  `DTPlatformName=iphoneos`, `DTPlatformVersion` and `DTSDKName` from the SDK export
  manifest, `DTXcode`/`DTXcodeBuild` from the manifest Xcode version/build, and
  `DTCompiler`. `BuildMachineOSBuild` is explicitly removed (never invented on Linux).
- Also fixed iPad orientation support (`UISupportedInterfaceOrientations~ipad` with
  all four orientations) to satisfy `ITMS-90474`.
- Verified against a known-good Xcode-produced Info.plist that the emitted keys match.

### Finding 2 (open): app icon requires a compiled Assets.car

- `ITMS-90022`/`ITMS-90023` (no 120x120/152x152 icon) and `ITMS-90713` (no
  `CFBundleIconName` in an asset catalog) persist even after generating the full
  `Icon-*.png` set and setting `CFBundleIconName`/`CFBundleIcons`.
- Conclusion: for an iOS 11+ SDK build, App Store Connect requires a compiled
  `Assets.car`. Loose PNGs plus `CFBundleIconName` are insufficient, and no maintained
  cross-platform `.car` writer exists (readers do: Timac's format write-up, darling,
  cartool, ThemeEngine).
- The xtool Linux icon path was never App Store-validated; released xtool apps went
  through Xcode export, which embeds `Assets.car`.
- Implemented native icon generation with the pure-Swift `swift-png` dependency
  (`IconGenerator`), eliminating any external image tool. Added an optional
  `assetCatalogPath` config field so a precompiled `Assets.car` can be embedded for
  validating the rest of the flow; this is a test hook, not the Linux-native solution.

### Decisions

- Keep the `swift-png` dependency (Apache-2.0) for native PNG decode/resize/encode.
- Next phase must implement a native `Assets.car` writer for the app-icon subset and
  wire it into the packer, replacing the `assetCatalogPath` hook.
- Do not copy GPL `darling` CoreUI/BOM sources; use the public format documentation
  for a clean-room writer and record any adapted third-party code and its license.

### Verification

- 40 unit tests pass across six suites (added IconGenerator and BuildSystemKey tests).
- The live upload produced the App Store Connect rejection email above; both error
  classes are now understood and one is fixed in this repository.
- The exact `Assets.car` produced by macOS `actool` for the proof icon is available
  locally for differential testing against a native writer.

### Follow-Up

- Implement the native `Assets.car` writer, re-run the live upload, and complete the
  Gate 2 TestFlight installation proof.

## 2026-08-16 - Native Assets.car Writer

### Summary

- Implemented a native, dependency-free `Assets.car` writer for the app-icon subset
  (`Sources/BuildCore/AssetCatalogWriter.swift`) and wired it into the packer, so
  `stupid-app build` and `stupid-app release archive` now embed a real compiled asset
  catalog instead of requiring a precompiled `actool` output.
- Replaced the `assetCatalogPath` test hook with automatic generation; the config
  field, its validation, and its error case were removed (`AppConfig`).
- Added a read-only `BOMStoreReader` (test support) and structural/differential
  `AssetCatalogWriterTests`.

### The `.car` format (reverse-engineered)

- A `.car` is a NeXTSTEP `BOMStore` container (big-endian header/block table/free
  list + a named-block variables table), holding CoreUI blocks and B+ trees.
- Required blocks/trees for an AppIcon catalog: `CARHEADER` (436-byte `RATC`
  header), `KEYFORMAT` (`tmfk`), `EXTENDED_METADATA` (`META`), and the
  `RENDITIONS`, `FACETKEYS`, `APPEARANCEKEYS`, `BITMAPKEYS` trees. Each tree has a
  header block plus a single leaf node whose entries map `(valueBlock, keyBlock)`
  and which also carries inline key copies (the bytes CoreUI actually reads).
- Each rendition value is a 184-byte `ISTC` CSI header plus TLV metadata and a
  payload: the marketing icon is a `CUIThemePixelRendition` (`MLEC`/`CELM` wrapper)
  and the size set is a MultiSized Image (`SISM`).
- **Pixel data is stored uncompressed** (`MLEC`, compression type 0, raw ARGB).
  This avoids LZFSE entirely and is accepted by Apple's own tooling.

### Verification

- The writer output is structurally byte-identical to the `actool`-produced
  reference for every block except the CARHEADER timestamp and the intentionally
  different pixel payload.
- Apple's `assetutil --info`, `assetutil --validate-file` ("valid bitmapindex",
  "valid keyformat", "all image blocks are valid", "all multisize image (icon) size
  classes are valid"), and `assetutil` thinning all accept the generated car.
- A `testGeneratedCarMatchesActoolReferenceStructure` test compares the generated
  car against the reference `.car` when `ASSET_CATALOG_REFERENCE` is set (a local
  path), and skips otherwise so CI/Linux runs stay hermetic.
- 52 unit tests pass across nine suites.

### Decisions

- **Uncompressed pixels over LZFSE:** the format declares compression type 0 as
  "uncompressed", and Apple's tools validate it; a from-scratch LZFSE encoder is
  unnecessary and would be a large dependency.
- **Clean-room implementation:** the writer was built from the public format
  documentation (dbg.re, Timac's write-up, `bomutils` `bom.h`); no GPL `darling`
  source was copied. The `carfile-go` library was used only as a read reference.
- **Inline keys are emitted twice** (separate key blocks plus the inline copies in
  the leaf) because CoreUI reads the inline copies while a Go reader reads the
  blocks; replicating actool's exact layout keeps both working.

### Follow-Up

- Re-run the live Gate 2 upload on the isolated WSL host with the generated
  `Assets.car` to confirm App Store validation passes, then complete the TestFlight
  installation proof.

## 2026-08-16 - Credential Store Simplification, Gate 3 Partial Proof, And Additional Gate 2 Rejections

### Summary

- Removed credential encryption and all passphrase handling. `CredentialStore` now
  writes plaintext secret files atomically with mode `0600` inside a mode `0700`
  directory; the owning account and root/sudo can read them.
- Removed `--credential-password`, `STUPID_APP_CREDENTIAL_PASSWORD`, and the legacy
  environment fallback after credential-store read failures.
- Migrated the isolated WSL credential store in place to the new plaintext format and
  verified owner/mode settings without printing secret values.
- Implemented the Gate 3 development-signing and USB-run command paths, provisioned a
  development identity/profile, and reached the USB installation phase on a physical
  device. Installation stalled after a usbmux connection error, so Gate 3 remains open.
- Executed two additional Gate 2 uploads with native `Assets.car` variants. Both
  reached App Store validation and failed with `ITMS-90022`, `ITMS-90023`, and
  `ITMS-90713`; no build reached processing or TestFlight.

### Credential Incident And Decision

- The encrypted store had become internally inconsistent: ASC/distribution secrets
  used the original passphrase, while development identity files and the shared team-ID
  file used a later Gate 3 passphrase.
- Root cause: `ASCContext.resolve` used `try?` for credential reads. A decryption error
  was silently discarded, legacy ASC environment variables allowed the operation to
  continue, and the returned store still used the newly supplied passphrase.
  Development setup then rewrote only development secrets and the shared team ID.
- The immediate fix removes the passphrase and fallback paths entirely. Credential
  read failures now fail loudly. This is a deliberate technical-validation tradeoff,
  not a claim that plaintext files are appropriate for every production environment.
- The WSL credential directory is `0700`; ASC keys and signing private keys are `0600`.
  WSL virtual disks, exports, snapshots, backups, and the host account remain
  secret-bearing.
- Temporary diagnostic scripts containing the supplied passphrase and extracted IPA
  contents were removed from the macOS, Windows, and WSL hosts after migration.

### Gate 3 Work Completed

- Added public ASC operations and models for device listing/registration, Apple
  Development certificates, and `IOS_APP_DEVELOPMENT` profiles.
- Added separate development/distribution identity storage, development entitlement
  derivation, a shared `SigningPipeline`, `DeviceKit`, `devices`, and `run --usb`.
- Installed and validated Windows-to-WSL USB pass-through, `usbmuxd`, pairing, and
  `pymobiledevice3` device visibility. A development IPA built, signed once with a real
  Apple Development identity, and packaged successfully.
- The first install remained stuck for several minutes and the connection reported a
  usbmux error. The process was terminated and no installation or launch success is
  claimed. Follow-up needs bounded installer output, timeout/cancellation, and clean
  usbmux lifecycle diagnostics.

### Gate 2 Live Results

- A fresh distribution archive contained the required build-system Info.plist keys,
  `CFBundleIconName=AppIcon`, loose phone/iPad icon PNGs, a native `Assets.car`, a real
  App Store profile, and a valid distribution signature.
- First follow-up catalog: `MLEC` compression type 0 with raw ARGB. macOS `assetutil`
  accepted `--info`, `--validate-file`, and thinning. App Store validation still
  returned all three icon errors.
- Differential inspection against the local `actool` golden catalog showed matching
  BOMStore structure, named blocks, key format, rendition/facet keys, phone/iPad icon
  records, and multisize records. The material difference was pixel compression.
- Second follow-up catalog: type-4 `MLEC` with the same four `KCBC` row chunks as
  `actool`, each containing a valid raw (`bvx-`) LZFSE stream. `assetutil --info`
  reported `Compression: lzfse` for phone and iPad, and `--validate-file` reported valid
  bitmap index, key format, image blocks, and multisize icon classes. App Store
  validation still returned the same icon errors.
- The `actool` golden catalog uses genuinely compressed LZFSE v2 (`bvx2`) streams.
  The next controlled change is to integrate a pinned, auditable LZFSE encoder and emit
  `bvx2` streams inside the existing KCBC wrapper. Local `assetutil` acceptance must no
  longer be treated as sufficient proof.
- The official Apple reference implementation is the BSD-3-Clause `lzfse/lzfse`
  repository. The inspected upstream snapshot was commit
  `e634ca58b4821d9f3d560cdc6df5dec02ffc93fd`; it has not been adopted or pinned by
  this project yet.

### Verification

- `swift format` was run for modified Swift files.
- `swift test` passes 52 tests across nine Swift Testing suites plus five
  `AssetCatalogWriterTests` XCTest cases.
- The optional `actool` structural golden comparison passed with
  `ASSET_CATALOG_REFERENCE` set to the local reference catalog.
- The CLI rebuilt on the isolated x86_64 Ubuntu WSL host and produced fresh
  distribution-signed archives for both follow-up uploads.
- Both live uploads completed Build Upload creation, file reservation, delivery,
  checksum commit, and state polling before failing at App Store icon validation.
- No release manifest was produced because no upload yielded a build resource.

### Takeover State

- Gate 2 is not complete. Proof build numbers 3, 4, and 5 were used by failed uploads;
  use 6 or later next.
- The current writer emits type-4 MLEC/KCBC payloads with raw LZFSE blocks. Replace only
  the inner stream encoder first; preserve the already-matched container and metadata.
- Prefer Apple's BSD-licensed reference LZFSE implementation at a pinned commit, or an
  equivalently auditable compatible encoder. Record source provenance and license
  obligations before committing copied or vendored code.
- If genuinely compressed payloads still fail, make one diagnostic upload using the
  exact local `actool` golden `Assets.car` to isolate whether the blocker is payload
  encoding or another App Store packaging rule. Do not make that macOS artifact a
  product dependency.
- Resume Gate 3 only after Gate 2 unless priorities change. Gate 3's remaining proof is
  a successful USB install and launch; network transport remains Gate 4.

## 2026-08-16 - Gate 3 Detailed Takeover State

This entry is a hand-off record so a different engineer can resume the Gate 3
(development signing + USB install) proof from exactly where it stopped. It overlaps
the earlier "Credential Store Simplification, Gate 3 Partial Proof" entry but records
concrete state, repro commands, and the open blocker. Keep this entry current as Gate 3
progresses; fold it into the handover's Gate 3 status when the exit condition is met.

### Status

- **Exit condition (not met):** the app launches on the registered physical device with
  a valid Apple Development signature.
- **Reached so far:** device registered; development certificate minted; device
  development profile created; development IPA built, signed once with a real Apple
  Development identity, and packaged; Windows-to-WSL USB pass-through, device pairing,
  and `pymobiledevice3` device visibility all validated.
- **Blocked at:** the `pymobiledevice3 apps install` step, which started and then stalled
  after a usbmux connection error. The process was terminated after several minutes.
  No install or launch success is claimed.

### Implemented Code (working tree, builds + 52 tests pass)

- `ASCKit/ASCOperations`: list/find/register devices; a generalized certificate create
  with `DEVELOPMENT` type; a generalized profile create with `IOS_APP_DEVELOPMENT` and a
  device relationship; profile lookup is now profile-type-parameterized; pure decode
  helpers (`decodeDeviceList`, `decodeCreatedDevice`, `matchProfileID`,
  `decodeCreatedResourceID`) for unit tests.
- `SigningKit/IdentityManager`: separate development/distribution identities
  (`development.key.pem`, `development.cert.pem`, `development.cert.id`,
  `distribution.*`), stored via the plaintext `CredentialStore`.
- `SigningKit/EntitlementDeriver`: development configuration forces
  `get-task-allow=true`.
- `SigningKit/SigningPipeline`: one shared derive-entitlements → embed-profile → sign →
  package-IPA boundary used by both `release archive` and `run --usb`.
- `DeviceKit` (new module): `DeviceInstaller` protocol +
  `PyMobileDevice3Installer` (install, launch via `developer dvt launch`,
  `usbDeviceUDIDs`, optional `--usbmux` address with automatic Linux unix-socket
  detection at `/var/run/usbmuxd`).
- CLI: `signing setup --kind development` (with `--udid`/`--device-name`),
  `devices list|add`, `run --usb`.
- `ASCContext` reads plaintext credentials and fails loudly on missing secrets; there is
  no passphrase and no environment fallback.

### Device / Host Infrastructure (validated)

- Host: the existing Windows machine over SSH (administrator shell). WSL 2
  distribution `iosdev-ubuntu`.
- `usbipd-win` 5.3.0 installed via `winget`. A physical iPhone was passed through with
  `usbipd bind --force --busid <busid>` then `usbipd attach --wsl iosdev-ubuntu
  --busid <busid>`. The Apple USB driver must be released first: disable the `Apple
  Mobile Device USB Device` PnP interface, which required a Windows reboot to complete
  ("Device is pending system reboot to complete a previous operation"). After reboot the
  interfaces show `Unknown` and the device attaches cleanly.
- WSL: `usbutils` (`lsusb`), `usbmuxd` (runs as a systemd service, socket
  `/var/run/usbmuxd`), `libimobiledevice-utils` (`idevice_id`, `ideviceinfo`,
  `idevicepair`), `pymobiledevice3` in `~/.venvs/pmd3`, pinned `rcodesign` 0.29.0 at
  `~/.local/bin/rcodesign`. Swift SDK is registered as `ios-dev`.
- **`C:\Users\<user>\.wslconfig` now sets `networkingMode=mirrored` and
  `vmIdleTimeout=-1`.** The WSL 2 VM was stopping between commands, which invalidated the
  (non-persistent) usbipd attach and killed `usbmuxd`, producing the observed `Mux error
  (-8)` / lockdownd failures. Keeping the VM alive is expected to fix most of the
  instability seen this session.
- Credentials live in the plaintext `~/.stupid-app/credentials` store (mode `0700` dir,
  `0600` files): ASC key, issuer, team ID, distribution identity + App Store profile,
  and now a development identity + development profile
  (`profiles/<bundle-id> Development.mobileprovision`).

### Resuming The Proof (WSL)

1. Confirm the VM stayed up (`wsl.exe -d iosdev-ubuntu -u iosdev --exec bash -lc 'echo ok'`
   and `wsl.exe --list --running`). If it stopped, start it and keep it alive.
2. If the USB attach dropped, re-attach from the Windows admin shell (non-persistent).
   Then in WSL as root confirm the device + pairing:
   `lsusb | grep -i apple`, `idevicepair validate`, `idevice_id -l`, and journal
   `usbmuxd.service`.
3. Provisioning is already done, but the exact one-time command is:
   `stupid-app signing setup --kind development --bundle-id <bundle-id> --udid <udid>
   --device-name "<name>"` (register device, mint dev cert, create dev profile).
4. Run the full flow from `~/AcceptanceApp`:
   `stupid-app run --usb --udid <udid> --sdk-id ios-dev
   --rcodesign ~/.local/bin/rcodesign
   --pymobiledevice3 ~/.venvs/pmd3/bin/pymobiledevice3 --usbmux /var/run/usbmuxd`.
   It rebuilds the debug app each invocation, signs once (development), packages the
   IPA under `.build/arm64-apple-ios/debug/`, then installs and launches.

### Open Blocker And Investigation Notes

- The install step reached `pymobiledevice3 apps install` and hung; lockdownd then
  reported `Mux error (-8)`. The most likely cause was the WSL VM/`usbmuxd` instability
  described above rather than the signing output (the IPA itself validated with
  `rcodesign print-signature-info` and packaged cleanly). Re-test now that the VM stays
  up.
- Launch uses `pymobiledevice3 developer dvt launch`, which requires Developer Mode
  enabled on the device. Confirm/enable it on the iPhone before expecting launch
  success; check with `pymobiledevice3 amfi` / `developer dvt` if needed.
- The device must be unlocked (screen on) during install; a locked device can make the
  install wait indefinitely.

### Code Gaps To Fix Before Declaring Gate 3

- `DeviceKit/ProcessRunner` only `terminate()`s a stuck child; per the handover it must
  escalate interrupt → terminate → kill, own the process group, honor cancellation, and
  bound captured output. Give `PyMobileDevice3Installer` an explicit timeout and a
  public-safe way to surface bounded installer progress/stderr without leaking
  device-specific detail.
- Keep build, sign, install, launch separable instead of one `run` monolith, per the
  handover; `run --usb` currently composes them.
- Consider a helper that re-establishes the non-persistent usbipd attach so a re-run
  does not silently hang on a missing device.
- Developer Mode should be surfaced as an actionable error from the launch step rather
  than a raw `pymobiledevice3` failure.

### Gate Ordering

The handover currently says complete Gate 2 (the App Store `Assets.car` LZFSE encoding
blocker) before resuming Gate 3 transport. If instead Gate 3 is resumed first, start with
the "Resuming The Proof" steps above and the DeviceKit timeout/cleanup fixes.

## 2026-08-16 - Gate 2 Complete: Valid Linux Build And TestFlight Launch

### Summary

- Vendored Apple's BSD-3-Clause LZFSE reference implementation at commit
  `e634ca58b4821d9f3d560cdc6df5dec02ffc93fd` as the `CLZFSE` target and recorded its
  license in `THIRD_PARTY_NOTICES.md`.
- Replaced raw `bvx-` icon streams with genuinely compressed `bvx2` streams while
  preserving the already-matched BOM/CoreUI catalog structure.
- Added `CFBundleIconName=AppIcon` inside both phone and iPad
  `CFBundlePrimaryIcon` dictionaries, matching `actool`'s partial Info.plist output.
- Completed the Linux archive, direct Build Upload, processing, internal TestFlight,
  installation, and launch proof. Gate 2's exit condition is met.
- Finalized the Gate 2 diagnostic artifact as the public-safe release manifest rather
  than retaining raw API bodies. The manifest preserves artifact identity, upload/build
  resource identity, and terminal states without increasing secret or personal-data
  retention.

### Live Findings

- Build 6 used the native catalog with eight compressed `bvx2` chunks but retained only
  the top-level icon-name key. App Store Connect returned the same icon validation
  errors, proving compression alone was insufficient.
- Comparing `actool` output exposed the missing nested icon-name values. Build 7 added
  those values and processed as `VALID`; its beta state stopped only at
  `MISSING_EXPORT_COMPLIANCE`.
- The proof app uses no non-exempt encryption. Build 8 declared
  `ITSAppUsesNonExemptEncryption=false`, processed as `VALID`, reached
  `READY_FOR_BETA_TESTING`, wrote the release manifest, installed through TestFlight,
  and launched successfully.
- The accepted IPA SHA-256 is
  `79ed5d700e466dd435e0b706f54aeb07ade2bd9f0dc3c4519c637b35ee38066c`.

### Verification

- `swift test` on macOS: 53 Swift Testing cases and six catalog XCTest cases passed;
  the optional local `actool` structural golden test skipped when its path was unset.
- The macOS-gated catalog test ran `xcrun assetutil --validate-file` successfully.
- `swift test` on x86_64 Ubuntu WSL: 53 Swift Testing cases and five catalog XCTest
  cases passed; the two macOS/local-reference checks skipped as designed.
- `swift build -c release` succeeded on macOS and x86_64 Ubuntu WSL.
- `stupid-app release archive --sdk-id ios-dev` produced a one-pass
  distribution-signed IPA on Linux with timestamps disabled.
- `stupid-app release upload --wait --sdk-id ios-dev` completed the Build Upload,
  resolved the exact version/build, reported `processing=VALID` and
  `internal=READY_FOR_BETA_TESTING`, and wrote `.release/release-manifest.json`.

### Follow-Up

- Gate 3 is now the next proof gate. Resume from the detailed takeover entry above,
  add bounded installer diagnostics and process cleanup, then prove USB installation
  and launch before Gate 4 wireless transport work.

## 2026-08-16 - Gate 3 Complete: Development Install And CoreDevice Launch

### Summary

- Completed the Gate 3 physical-device proof on the isolated WSL host: build,
  development entitlement reconciliation, one real Apple Development signing pass,
  IPA packaging, USB installation, and launch all succeeded.
- Hardened `ProcessRunner` to drain stdout/stderr continuously into bounded tail
  buffers, honor timeout and task cancellation, and escalate interrupt, terminate,
  and kill signals to the Linux process group.
- Added bounded discovery/install/launch timeouts to `PyMobileDevice3Installer`, passed
  the configured usbmux socket to discovery, parsed both JSON-array and legacy text
  device lists, redacted the selected device identifier from diagnostics, and installed
  the development IPA with `--developer`.
- Added `--install-timeout` and `--launch-timeout` to `stupid-app run`.

### USBIP Root Cause

- The stock Ubuntu `usbmuxd` 1.1.1 uses a 49,152-byte USB transmit unit and relies on a
  zero-length packet to preserve the transfer boundary. WSL USBIP loses that boundary,
  coalescing transfers; the device reports that it received roughly 59 KB while it
  expected one 49,152-byte frame, and AFC installation stalls.
- This matches the still-open `usbipd-win` issue #959. Reducing the transmit unit to
  16,384 bytes did not help because it still relies on a zero-length packet. A
  diagnostic `usbmuxd` 1.1.1 build with `USB_MTU=16383` forced a physical short-packet
  boundary and immediately completed the 58 KB IPA transfer at 90% and 100%.
- The diagnostic daemon is GPL-3.0 and is not committed or adopted as a product
  dependency. Gate 4 must decide how to provision, checksum, license, and lifecycle a
  qualified transport rather than depending on a hand-built daemon.

### Launch Proof

- Developer Mode was enabled and a personalized Developer Disk Image was already
  mounted. The legacy `developer dvt launch` lockdown path returned `InvalidService` on
  iOS 26.6, so direct USB DVT is not a valid modern launch mechanism.
- Pinned `pymobiledevice3` 8.2.1 successfully launched the installed app through the
  modern path: usbmux lockdown, `CoreDeviceTunnelProxy`, TCP tunnel, Remote Service
  Discovery, and `AppServiceService.launch_application`. The device returned a live
  process token.
- The tunnel requires access to `/dev/net/tun`; the same helper run as the unprivileged
  build user failed with `Operation not permitted`. Gate 4 must make this privilege and
  route lifecycle explicit. The CLI must not silently elevate privileges.
- The WSL environment had accidentally installed `pymobiledevice3` 10.7.4 despite the
  8.2.1 reference pin. The proof used a separate 8.2.1 environment; because its broad
  dependency constraint currently resolves an incompatible `construct-typing` 0.8.1,
  the proof environment pinned `construct-typing` 0.7.0. A complete lock/checksum set is
  still required before product integration.

### Verification

- macOS: 59 Swift Testing cases and six catalog XCTest cases passed; the optional local
  catalog reference check skipped, and the macOS `assetutil` qualification passed.
  `swift build -c release` also succeeded.
- x86_64 Ubuntu WSL: 60 Swift Testing cases and five catalog XCTest cases passed; the
  two macOS/local-reference checks skipped as designed. This includes high-volume pipe,
  timeout, device-adapter, and Linux process-group cleanup coverage with no surviving
  helper.
- The CLI rebuilt the debug app, derived development entitlements, signed exactly once,
  and packaged the development IPA on WSL.
- The USBIP-compatible daemon completed installation of that IPA on the registered,
  paired physical device.
- The USB-bootstrapped CoreDevice helper launched the exact installed bundle and
  returned a process identifier. Gate 3's exit condition is met.

### Follow-Up

- Gate 4 must integrate bounded CoreDevice bootstrap, remote pairing, tunnel, route,
  install, and launch lifecycle into `DeviceKit`; provision pinned and checksummed
  Python and usbmux transport dependencies; and prove three consecutive unplugged runs
  without stale helper cleanup.

## 2026-08-16 - Deferred Native USB Transport Task

### Decision

- Added a future task for a native Swift `DeviceKit` USB backend that directly owns the
  Apple mobile-device USB interface and usbmux v2 framing instead of requiring an
  external `usbmuxd` process for the direct USB connection path.
- Classified the task as explicitly non-blocking. Gate 4 may proceed with the qualified
  pinned helper transport, and Gate 5 does not require the native backend unless a later
  architectural decision promotes it into scope.
- Recorded eventual acceptance criteria covering WSL USBIP packet boundaries,
  discovery and connection lifecycle, pairing-record handling, cancellation and cleanup,
  protocol fixtures, physical-device qualification, replaceable transport boundaries,
  fail-loud backend selection, and third-party licensing/provenance review.

### Verification

- Documentation-only backlog change; no source, configuration, command behavior, or
  proof-gate status changed.

## 2026-08-16 - Gate 4 Complete: Unplugged Network Install And Launch

### Summary

- Implemented `stupid-app device pair --usb` for lockdown pairing, wireless-connection
  enablement, USB CoreDevice bootstrap, remote pairing, and permission-hardened pairing
  record persistence.
- Implemented `stupid-app run --network --udid <udid>` using one bounded helper lifetime
  for mDNS discovery, remote-pair candidate connection, TCP tunnel creation, RSD device
  verification, developer IPA installation, installed-bundle verification, AppService
  launch, and cleanup.
- Replaced the USB run path's invalid legacy DVT launch with the same modern CoreDevice
  helper through a USB-bootstrapped tunnel.
- Added `CoreDeviceRunner`, a bundled Python helper resource, explicit `--sudo` and
  `--coredevice-helper` boundaries, bounded/redacted diagnostics, and tests covering
  command composition, installed-helper selection, permission setup, explicit sudo
  invocation, missing binaries, and identifier redaction.
- Added a frozen uv environment under `Tools/pymobiledevice3` and documented the
  pymobiledevice3 GPL-3.0-or-later runtime dependency.

### Transport Findings

- USB CoreDevice bootstrap created a remote pairing record without requiring a
  persistent tunnel daemon. The record is stored as mode `0600` inside a mode `0700`
  credential subdirectory and remains owned by the unprivileged deployment account
  after the privileged helper exits.
- Python 3.12 with pymobiledevice3's `sslpsk-pmd3` compatibility layer completed remote
  pair verification but failed the TCP tunnel TLS handshake with
  `NO_CIPHERS_AVAILABLE`. Gate 3 had not exercised this TLS path because its USB proxy
  tunnel does not use the remote-pairing TLS listener.
- Python 3.13's native TLS-PSK support completed the same TCP tunnel successfully.
  Python 3.13 is therefore part of the Gate 4 compatibility pin; the frozen environment
  retains pymobiledevice3 8.2.1 and construct-typing 0.7.0.
- The mDNS browser can return duplicate advertisements and addresses. Candidate tuples
  are deduplicated before connection. Advertised service identifiers are not assumed to
  equal saved remote-pairing identifiers; the selected physical device is verified only
  after RSD reports its actual device UDID.
- Building as root is invalid because Swift SDK registration is user-scoped. The proven
  boundary keeps build and signing unprivileged and permits only a root-owned helper
  invocation through an explicit sudo policy. The CLI never silently elevates.

### Physical Verification

- The isolated x86_64 Ubuntu WSL host discovered the phone over mDNS after physical USB
  disconnection.
- Three consecutive `run --network` operations rebuilt the fixture, reconciled
  development entitlements, signed exactly once, packaged the IPA, created a TCP tunnel,
  installed and verified the bundle, and launched it on the physical device.
- The first two commands returned complete success and reported zero USB devices, zero
  helper processes, and zero residual pymobiledevice3 tunnel interfaces.
- The third command launched the app on-device before its controlling SSH stream was
  interrupted. An immediate independent inspection reported zero USB devices, zero CLI
  processes, zero helper processes, and zero residual tunnel interfaces.
- Gate 4's three-consecutive-unplugged-runs exit condition is met.

### Automated Verification

- macOS: `swift test` passed 63 Swift Testing cases and six catalog XCTest cases; the
  optional local differential catalog test skipped. `swift build -c release` passed.
- x86_64 Ubuntu WSL: `swift test` passed 64 Swift Testing cases and five catalog XCTest
  cases; the expected macOS-only catalog checks skipped. `swift build -c release`
  passed.
- The frozen Python environment installed from `uv.lock`; the helper's exact Python,
  pymobiledevice3, and construct-typing checks passed before device operations.

### Follow-Up

- Gate 5 must automate frozen-environment provisioning, root-owned helper installation,
  least-privilege sudo policy setup, and the qualified USBIP-compatible usbmux transport.
- Add `doctor` checks for Python/package pins, `/dev/net/tun`, privilege policy, pairing
  directory modes, mDNS reachability, signer availability, and SDK compatibility.

## 2026-08-16 - Gate 5 Started: Product Diagnostics

### Summary

- Added `stupid-app doctor` and a testable `ProductCore` integration module.
- Added structured pass, warning, and failure results for the host Swift toolchain,
  installed iOS Swift SDK, rcodesign, frozen CoreDevice environment, USB installer,
  App Store Connect credentials, development/distribution identities, pairing records,
  project configuration, and Linux TUN/usbmux prerequisites.
- Exposed installed SDK manifest loading through `SDKVersion.installedManifest` so the
  doctor can compare the current host triple and Swift major/minor version against the
  imported bundle rather than checking registration alone.
- Replaced the device installer's unpinned `pip install pymobiledevice3` recovery advice
  with the repository's frozen `uv.lock` provisioning requirement.

### Diagnostics And Security

- Required environment defects fail the command; absent credentials, identities,
  pairing records, project context, or the USB socket are warnings where another
  workflow can still be used.
- Credential and signing checks inspect only expected file presence and POSIX modes.
  They do not load or print secret values.
- Credential directories must be mode `0700`; secret and pairing-record files must be
  mode `0600`.
- Frozen-environment validation invokes the bundled helper's existing exact checks for
  Python 3.13, pymobiledevice3 8.2.1, and construct-typing 0.7.0 using a temporary
  pairing directory. Running the doctor does not create or alter credential state.
- Project checks validate `stupid-app.yml` and require `Package.swift` plus every
  configured Info.plist, entitlement, icon, and raw-resource path to exist.

### Verification

- `swift format` completed for all modified Swift files.
- `swift test --filter DoctorTests` passed all three new diagnostic tests.
- `swift test` passed 66 Swift Testing cases plus seven asset-catalog XCTest cases; the
  optional local catalog-reference test skipped as designed.
- `swift build -c release` passed.
- `stupid-app --help` and `stupid-app doctor --help` expose the new command and options.
- A real local doctor run reported the available host checks and failed the deliberately
  unavailable/incompatible SDK, signer, and frozen Python checks with actionable output;
  no secret values were printed.

### Remaining Gate 5 Work

- Automate the frozen Python environment and root-owned helper installation with a
  least-privilege sudo policy.
- Provision the qualified WSL USBIP-compatible usbmux transport with explicit GPL
  compliance.
- Add `release status`, broader compatibility/fixture tests, and clean-host setup and
  recovery documentation.
- Run the complete acceptance flow through stable commands on clean supported hosts.

## 2026-08-17 - Native Signing And Device Stack Scope

### Summary

- Scoped project-owned Swift replacements for the pinned `rcodesign` signing kernel and
  `pymobiledevice3` device stack in `docs/native-dependency-replacement-scope.md`.
- Kept the work outside the current Gate 5 critical path. Existing dependencies remain
  authoritative until native implementations pass equivalent independent macOS,
  physical-device, and App Store acceptance gates.
- Identified the first decisive experiments as a read-only native code-signature
  parser/verifier and a SwiftNIO SSL TLS-PSK interoperability proof.

### Signing Findings

- The existing `SigningPipeline` is already a narrow replacement boundary: iOS profile,
  entitlement, and IPA policy can remain project-owned while a native kernel takes over
  resource sealing, Mach-O mutation, CodeDirectory, requirements, XML/DER entitlement
  slots, and Apple-compatible CMS.
- The first native engine should accept only one shallow, thin ARM64 app executable and
  fail loudly on frameworks, dylibs, extensions, fat binaries, and unknown signable
  descendants until leaf-first nested signing exists.
- Native signing cannot be accepted from self-verification alone. Qualification requires
  macOS `codesign --verify --strict`, physical-device development launch, App Store
  `VALID`/TestFlight readiness, and TestFlight installation of artifacts signed only by
  the native engine.

### Device Findings

- Replacing the Python helper requires usbmux/lockdown, modern remote pairing, mDNS,
  TLS-PSK, TUN forwarding, RemoteXPC/RSD, AFC, installation proxy, and AppService launch.
- Python 3.13, `uv`, `pymobiledevice3`, and their transitive environment can eventually
  be removed. Linux TUN privilege, multicast/IPv6, WSL USBIP, and external `usbmuxd`
  remain unless separately replaced.
- Raw USB ownership and usbmux v2 multiplexing remain a distinct deferred project. The
  native device stack should first continue using the qualified `usbmuxd` socket.
- The TLS-PSK proof should precede the full port because the prior Python 3.12 failure
  showed this transport layer is an architecture-level compatibility gate.

### Verification

- Reviewed the current signing and device adapter boundaries, the pinned
  `apple-platform-rs` source, and the pinned `pymobiledevice3` modules used by the bundled
  helper.
- This was documentation and architecture research only. No runtime behavior, dependency
  pin, source implementation, or proof-gate status changed.

## 2026-08-17 - Native Go/No-Go Spikes Promoted

### Decision

- Promoted the native signature parser/verifier and SwiftNIO SSL TLS-PSK interoperability
  spikes to the project's immediate next work.
- This supersedes the earlier classification of all native replacement work as outside
  the current critical path. Full native signer and CoreDevice implementations remain
  deferred until their respective spike produces a go result.
- Kept `rcodesign` and the pinned `pymobiledevice3` environment as the validated runtime
  defaults. There is no fallback, cutover, or proof-gate status change yet.

### Acceptance Boundaries

- The signing spike is read-only and must independently verify sanitized Xcode and
  `rcodesign` signatures, including mutation failures, without delegating verification
  back to `rcodesign`.
- The device spike is limited to a Swift TLS 1.2 PSK connection and one bounded
  `CDTunnel` exchange. The proven Python stack may create the listener, but Swift must own
  the tested TLS and handshake path.
- Both spikes require bounded public-safe diagnostics and deterministic cleanup.

### Verification

- Updated `docs/engineering-handover.md` with active status, go/no-go criteria, ordering,
  and the dependency-retirement guardrails.
- Documentation-only priority change; no source implementation or runtime behavior was
  modified.

## 2026-08-17 - Native Signature Parser And Hash Verification Slice

### Summary

- Started the promoted native signing spike with a read-only
  `SigningKit.NativeSignatureVerifier` implementation.
- Added bounded parsing for the supported thin little-endian ARM64 `MH_EXECUTE` shape,
  Mach-O load commands, final `__LINKEDIT` signature placement, `LC_CODE_SIGNATURE`, the
  embedded-signature SuperBlob, known slot/blob magic pairs, and SHA-256 CodeDirectory
  versions through `0x20600`.
- Added CodeDirectory verification for 4 KiB executable pages and embedded or external
  special-slot content. External content supplied by the caller must have a corresponding
  CodeDirectory hash and cannot be silently ignored.
- Kept the implementation disconnected from `SigningPipeline`; `rcodesign` remains the
  validated runtime signing kernel.

### Safety And Scope

- Relative offsets use overflow-checked arithmetic and bounded reads. Duplicate slots,
  overlapping blobs, truncated versioned headers, malformed hash tables, scatter vectors,
  unsupported hashes/page sizes, non-final signatures, and invalid `__LINKEDIT` placement
  fail loudly with public-safe errors.
- Input `Data` is normalized before relative offsets are applied so a non-zero-index slice
  cannot trap or shift parsing.
- The hash operation is named `verifyCodeDirectoryHashes` because matching page and slot
  hashes does not authenticate the CodeDirectory. CMS signature and certificate-chain
  verification remain mandatory before this can be called complete signature
  verification.

### Verification

- Added six hermetic tests using a synthetic ARM64 Mach-O/SuperBlob fixture with
  CodeDirectory, RequirementSet, XML-entitlement, and placeholder CMS blobs.
- Tests cover successful parsing, second-page mutation, embedded special-slot mutation,
  changed and missing external content, unsealed supplied external content, non-zero-index
  `Data` slices, malformed blob offsets, truncation, unsupported input, and invalid
  `__LINKEDIT` placement.
- `swift format` completed for the changed Swift source and test files.
- `swift test` passed 72 Swift Testing cases plus seven asset-catalog XCTest cases; the
  optional local `actool` differential test skipped as designed.
- `swift build -c release` passed. Existing warnings remain for the intentionally direct
  icon fixture and an unrelated unused provisioning-profile OID binding.

### Remaining Spike Work

- Parse and validate RequirementSet, XML entitlements, DER entitlements, CMS SignedData,
  and `CodeResources` semantics rather than treating those entries only as hashed blobs.
- Independently verify the CMS signature and Apple certificate chain without invoking
  `rcodesign`, then prove CodeDirectory mutation fails authentication.
- Freeze public-safe sanitized Xcode and `rcodesign` fixtures and run the parser plus all
  mutation classes against both before making a go/no-go decision.

## 2026-08-17 - Native XML And DER Entitlement Verification

### Summary

- Extended `SigningKit.NativeSignatureVerifier` to parse the XML entitlement plist and
  Apple's version-1 DER plist envelope from signature slots 5 and 7.
- Added a canonical `EntitlementValue` model for strings, Booleans, signed 64-bit
  integers, arrays, and nested dictionaries. Unsupported plist or ASN.1 value types fail
  loudly rather than being coerced.
- The parser now requires both entitlement representations and rejects semantic
  differences. DER dictionaries require nonempty, strictly ordered UTF-8 keys, which
  also rejects duplicate keys.
- Added `swift-asn1` as a direct `SigningKit` dependency. The wire-shape investigation
  used the pinned `apple-codesign` 0.29.0 `plist_der.rs` implementation as an auditable
  MPL-2.0 format reference; the Swift parser and test encoder were written for this
  repository rather than translated line by line.

### Verification

- Added hermetic entitlement coverage to the synthetic ARM64 signature fixture for
  strings, Booleans, integers, arrays, nested dictionaries, XML/DER mismatch, and
  noncanonical DER dictionary ordering.
- `swift format` completed for the modified package manifest, verifier, and tests.
- `swift test --filter NativeSignatureVerifierTests` passed all eight focused cases.
- `swift test` passed 74 Swift Testing cases plus seven asset-catalog XCTest cases; the
  optional local `actool` differential test skipped as designed.
- `swift build -c release` passed. The existing unrelated unused provisioning-profile
  OID warning remains.

### Remaining Spike Work

- Parse and validate RequirementSet semantics and `CodeResources`, including sealed-file
  and symlink mutations.
- Independently parse CMS SignedData, authenticate the complete CodeDirectory, and
  validate the Apple certificate chain without invoking `rcodesign`.
- Freeze sanitized Xcode and `rcodesign` fixtures and exercise every mutation class
  against both before deciding whether to promote the full native signer.

## 2026-08-17 - Native Designated Requirement Parsing

### Summary

- Extended `SigningKit.NativeSignatureVerifier` with a bounded parser for the embedded
  RequirementSet and its nested designated requirement blob.
- Limited the accepted shallow-app shape to exactly one designated flavor and one
  expression tree. The accepted operators are identifier, conjunction, Apple and Apple
  generic anchors, certificate field predicates, and certificate generic/OID predicates;
  match expressions are limited to `exists` and byte equality.
- Required the expression's single identifier to equal the CodeDirectory identifier.
  Certificate predicates are parsed but deliberately not evaluated yet because their
  authority depends on the still-unimplemented CMS leaf and chain authentication.
- Added explicit tree-depth and node-count limits and fail-loud checks for unknown
  flavors/opcodes/flags, malformed offsets and lengths, trailing data, invalid UTF-8,
  empty OIDs, and nonzero alignment padding.
- The binary-format investigation used the pinned `apple-codesign` 0.29.0
  `code_requirement.rs`, `embedded_signature.rs`, and `policy.rs` files as auditable
  MPL-2.0 references. The Swift parser was implemented directly against the bounded
  project scope rather than porting the complete requirement DSL.

### Verification

- Replaced the prior opaque requirement placeholder with a synthetic Apple-development
  designated requirement containing identifier, Apple generic anchor, leaf common-name
  equality, and WWDR certificate-extension existence predicates.
- Added deterministic tests for CodeDirectory identifier mismatch, unsupported opcodes,
  invalid nested-blob offsets, nonzero data padding, and mutation of otherwise valid
  certificate predicate content.
- `swift format lint --strict` passed for the package manifest, verifier, and verifier
  tests.
- `swift test --filter NativeSignatureVerifierTests` passed all 11 focused cases.
- `swift test` passed 77 Swift Testing cases plus seven asset-catalog XCTest cases; the
  optional local `actool` differential test skipped as designed.
- `swift build -c release` passed. Existing unrelated warnings remain for the unhandled
  icon test fixture and unused provisioning-profile OID binding.

### Remaining Spike Work

- Parse and verify `CodeResources`, including ordinary-file SHA-1/SHA-256 seals, symlink
  targets, rule application, path safety, and mutation failures.
- Parse CMS SignedData, authenticate the complete CodeDirectory and Apple certificate
  chain, then evaluate the parsed designated requirement certificate predicates against
  that authenticated chain.
- Freeze sanitized Xcode and `rcodesign` fixtures and exercise all parser and mutation
  classes against both before making the native-signing go/no-go decision.

## 2026-08-17 - Shallow-App Native Swift Signer Implemented

### Summary

- Implemented the complete project-owned signer for the deliberately narrow shallow-app
  shape: one thin little-endian ARM64 `MH_EXECUTE` executable, no nested signable code,
  4 KiB SHA-256 code pages, XML and Apple DER entitlements, and RSA identities.
- Added a fail-loud bundle classifier, deterministic SHA-1/SHA-256 `CodeResources`, Apple
  DER entitlement and WWDR RequirementSet serialization, CodeDirectory/SuperBlob
  construction, and final `LC_CODE_SIGNATURE` add/replace with `__LINKEDIT` file/vm sizing.
- CodeDirectory executable-segment flags always include `MAIN_BINARY`; development output
  with `get-task-allow=true` additionally includes `ALLOW_UNSIGNED`, while distribution
  output does not.
- Added detached CMS SignedData generation with RSA-SHA256 PKCS#1 v1.5, the leaf and
  caller-supplied WWDR intermediate, canonical signed attributes, and Apple cdhash OIDs
  `1.2.840.113635.100.9.1` and `1.2.840.113635.100.9.2`.
- Added independent CMS parsing and verification: detached content digest, both cdhash
  attributes, RSA signature, embedded chain signatures, caller-supplied root trust,
  certificate validity, RequirementSet certificate predicates, and timestamp absence.
- Added explicit `SigningPipeline` and CLI engine selection. `rcodesign` remains the
  default; native selection requires `--signer-engine native`, `--wwdr-intermediate`, and
  one or more `--trusted-apple-root` values. Missing chain input fails before signing and
  there is no silent fallback.

### Safety And Scope

- The classifier rejects malformed bundle metadata, executable symlinks, additional
  executable files, frameworks, extensions, helper/XPC directories, and dynamic
  libraries. The Mach-O editor rejects malformed commands, missing/finally misplaced
  `__LINKEDIT`, non-final existing signatures, duplicate signature commands, insufficient
  zero load-command space, and integer overflow.
- CMS construction deliberately emits no signing-time attribute, timestamp server call,
  unsigned RFC 3161 token, or other timestamp. Verification rejects an RFC 3161 token.
- WWDR and Apple root certificates are explicit operator inputs rather than hard-coded or
  downloaded implicitly. They are not committed to the repository.
- The implementation is not physically or App Store qualified. `rcodesign` remains the
  authoritative production path and no physical-device/App Store compatibility is
  claimed for native output.

### Verification

- `swift format lint --strict` passed for all new and modified Swift/package files.
- `swift test --filter SigningKitTests` passed 26 tests across five SigningKit suites.
- `swift test` passed 84 Swift Testing cases plus seven asset-catalog XCTest cases; the
  optional local `actool` differential test skipped because its path was unset.
- `swift build -c release` passed. The pre-existing unused provisioning-profile OID
  warning and unhandled icon fixture warning remain.
- `stupid-app release archive --help` exposes explicit signer-engine and certificate-chain
  options while reporting `rcodesign` as the default.
- New hermetic tests generate synthetic RSA root/intermediate/leaf certificates, prove
  deterministic CMS output and timestamp absence, exercise add/replace Mach-O mutation,
  reject nested code, sign a complete synthetic app, and independently reverify its code
  pages, special slots, executable-segment flags, resource seals, entitlements,
  requirements, CMS, and chain.

### Remaining External Gates

- Run differential parsing against sanitized Xcode and `rcodesign` development and
  distribution fixtures.
- Pass macOS `codesign --verify --strict` and signature-detail inspection on native output.
- Install and launch a development artifact signed only by the native engine on a
  registered physical device.
- Process a distribution artifact signed only by the native engine to App Store `VALID`
  and internal TestFlight readiness, then install and launch it through TestFlight.

## 2026-08-17 - Native Signer Apple Qualification Complete

### Summary

- Qualified the project-owned native signer with real Apple Development and Apple
  Distribution identities on the isolated Linux/WSL host.
- Selected the matching public Apple WWDR G3 intermediate by comparing the stored leaf
  issuer hash, and used the Apple Inc. root as the explicit trust anchor. No private
  certificate material or device identifier was copied into the repository or this log.
- Corrected three issues found only by independent/live verification: flat iOS bundles
  need Apple's no-`Resources/` CodeResources rule set; CodeDirectory executable segment
  base/limit must describe the Mach-O `__TEXT` file range; and CMS must embed the complete
  leaf, WWDR intermediate, and root chain for iOS runtime trust.
- Added regression coverage for flat-bundle resource rules, the `__TEXT` boundary, the
  full three-certificate CMS chain, and development executable-segment flags.

### Distribution Verification

- Produced a native-only distribution IPA on WSL. Exact IPA SHA-256:
  `c4bd808a8a014c3cfd2177956904b65c71c4ce7b792572f75ad68562ea5f56e2`.
- Transferred that exact IPA to macOS without re-signing or repackaging.
- `codesign --verify --strict --verbose=4` reported `valid on disk` and `satisfies its
  Designated Requirement`.
- Uploaded the same IPA through `stupid-app release upload --wait`. App Store processing
  reported `VALID`; internal beta reached `IN_BETA_TESTING`.
- The resulting TestFlight build installed and remained open on the physical device.

### Development Verification

- Produced a native-only development IPA with SHA-256
  `8c790e2967a8e1de70be887c5e28fc6f1af6f75ea6413a6d61601ddf7c29de28`.
- Installed and launched it through the existing unplugged CoreDevice network path.
- CoreDevice reported successful launch, and the app remained open on the physical
  device.
- A same-source `rcodesign` control build confirmed matching CodeDirectory version,
  flags, code limit, platform, `__TEXT` executable boundary, and executable-segment flags.

### Automated Verification

- WSL: the 26 SigningKit tests passed before live signing, and release builds completed.
- macOS: targeted `swift format lint --strict` passed; `swift test` passed 85 Swift
  Testing cases plus seven asset-catalog XCTest cases with one expected optional skip;
  `swift build -c release` passed.
- `git diff --check` passed. Existing unrelated warnings remain for the unhandled icon
  fixture and unused provisioning-profile OID binding.

### Follow-Up

- Native signing now satisfies the development, macOS, App Store, and TestFlight proof
  gates for the supported shallow-app shape.
- Productize trusted public certificate-chain provisioning, then make native signing the
  default and remove the `rcodesign` runtime dependency without retaining a fallback.

## 2026-08-17 - Native Signing Product Cutover Complete

### Summary

- Made the qualified project-owned native signer the only signing path for development
  runs and distribution archives.
- Removed the `RcodesignSigner` adapter and all `--rcodesign`, `--signer-engine`,
  `--wwdr-intermediate`, and `--trusted-apple-root` command options. There is no signer
  fallback or caller-selectable engine.
- Bundled Apple's public WWDR G3 intermediate and Apple Inc. root certificates as
  `SigningKit` resources. Their official DER SHA-256 values are pinned, and loading
  validates resource integrity, certificate signatures, self-signed root trust, and
  current validity.
- Added automatic leaf-chain selection. A stored signing identity must be signed by the
  qualified WWDR G3 intermediate; malformed leaves, another issuer, certificate
  rotation, missing resources, checksum changes, expiration, or an invalid chain fail
  loudly and require a tool update.
- Changed `doctor` from an external-signer executable check to native signing-trust
  validation, and changed release-manifest signer provenance to
  `native-shallow-v1`.
- Updated current architecture, risk, dependency-retirement, README, and historical
  `rcodesign` pin documentation. The pin remains only as qualification provenance.

### Verification

- `swift format lint --strict` passed for every Swift/package file changed by the
  cutover, and `git diff --check` passed.
- `swift test` passed 87 Swift Testing cases plus all seven asset-catalog XCTest cases;
  the optional local `actool` differential test skipped as designed.
- `swift build -c release` passed on macOS. Existing unrelated warnings remain for the
  unhandled icon fixture and an unused provisioning-profile OID binding.
- `release archive`, `run`, `release upload`, and `doctor` help output contain no
  external signer, engine-selection, or caller-supplied chain options.
- On the isolated x86_64 Ubuntu WSL host, a fresh release build of the cutover source
  archived the existing proof app with the real stored Apple Distribution identity and
  profile. Automatic bundled-chain selection succeeded, native post-sign verification
  passed, and the resulting IPA SHA-256 was
  `3ba857be1603c53751e328197d768f5ec143484434387b724b12f08e29749ea2`.
- The first source-transfer attempt failed before compilation because macOS tar emitted
  AppleDouble metadata files. Recreating the archive with metadata emission disabled
  resolved the transfer issue. Temporary source copies, scripts, and the signed WSL
  artifact were removed after verification.

### Remaining Limitation

- The bundled signing trust intentionally supports only the externally qualified WWDR
  G3 chain. Add and independently requalify a new pinned intermediate/root pair before
  WWDR G3 expires or before accepting identities issued from another Apple chain.
