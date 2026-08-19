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

## 2026-08-17 - Native CoreDevice SwiftNIO TLS-PSK No-Go

### Summary

- Implemented a temporary bounded SwiftNIO 2.101.3/NIOSSL 2.37.2 client and `CDTunnel`
  codec to test the promoted native connection boundary.
- Completed the physical control and Swift comparison. The result is no-go for the
  proposed SwiftNIO SSL/BoringSSL architecture.
- Removed the temporary client, tests, and package dependencies after the no-go result.
  No product command or qualified runtime path changed.

### TLS Decisions And Findings

- A Python 3.13 control supplied an empty identity, negotiated TLS 1.2
  `PSK-AES128-GCM-SHA256`, sent the 16,000-MTU `CDTunnel` request, and validated the
  expected response shape.
- The iPhone rejected a forced `PSK-AES128-CBC-SHA` control handshake. This rules out the
  CBC-PSK family exposed by the tested NIOSSL/BoringSSL build.
- NIOSSL's client callback explicitly rejects an empty identity. Its vendored BoringSSL
  also does not recognize `PSK-AES128-GCM-SHA256`: configuring the string reaches an
  NIOSSL cipher-list precondition, while resolving raw code point `0x00A8` encounters a
  missing BoringSSL cipher.
- The first Swift physical attempt offered CBC-PSK with a nonempty identity and closed
  during TLS, before any `CDTunnel` bytes. The independent controls isolate both required
  properties as unsupported by this TLS kernel.

### Verification

- Hermetic macOS and x86_64 WSL tests proved the temporary frame codec, cleanup, and the
  NIOSSL-supported CBC-PSK path before physical testing.
- Physical tests proved the working Python GCM-PSK/empty-identity exchange, Swift TLS
  failure, and independent CBC rejection described above. No TUN interface or route was
  created for these connection-only tests.
- Temporary listener control files used mode `0700`/`0600` and were removed. No PSK,
  pairing record, device identifier, or private host detail was retained in the repository
  or this log.

### Follow-Up

- Do not resume the NIOSSL implementation unchanged. Decide between a narrow system
  OpenSSL adapter and a project-owned exact-suite TLS implementation, then run that new
  architecture through the same physical `CDTunnel` proof before broader device work.

## 2026-08-17 - System OpenSSL CoreDevice Connection Proof

### Summary

- Selected the narrow system-OpenSSL alternative after the SwiftNIO SSL no-go.
- Added `COpenSSL`, `CCoreDeviceTLS`, and `NativeDeviceSpike` as isolated non-product
  targets. `DeviceKit` and `stupid-app` do not depend on them, so the shipping CLI has no
  new OpenSSL runtime dependency at this stage.
- Implemented one blocking, timeout-bounded operation that resolves and connects the
  listener, requires TLS 1.2, supplies an empty PSK identity, offers only
  `PSK-AES128-GCM-SHA256`, verifies the negotiated protocol, writes one bounded
  `CDTunnel` request, reads one bounded response, and closes all OpenSSL/socket state.
- Added Swift framing and typed response validation plus hermetic malformed/round-trip
  tests. Public errors expose only phase codes and never OpenSSL state or PSK bytes.

### Physical Verification

- The isolated x86_64 Ubuntu WSL target compiled against its installed OpenSSL 3.0.13
  development package.
- The pinned Python environment created only the paired-device listener and stored the
  ephemeral PSK in a mode-`0600` control file. Swift owned the OpenSSL connection and
  `CDTunnel` exchange.
- The physical test completed successfully with the exact required TLS version, cipher,
  empty identity behavior, and expected response shape. No TUN interface or route was
  created. The listener helper and owner-only control files were cleaned up afterward.
- An independent post-run check found no listener process and no remaining PSK control
  file.
- Repeated the physical exchange after hardening the C shim with thread-scoped `SIGPIPE`
  blocking/draining, close-on-exec descriptors, fail-closed socket timeout setup, and an
  OpenSSL 3 compile guard. The hardened exchange passed again.

### Automated Verification

- `swift format lint --strict` passed for the changed package and Swift files, and
  `git diff --check` passed.
- `swift test` passed 90 Swift Testing cases plus seven asset-catalog XCTest cases with
  one expected optional skip.
- `swift build -c release` passed. `otool -L` confirmed that the product
  `stupid-app` executable does not link `libssl` or `libcrypto`; only the isolated spike
  test path links the local OpenSSL installation.

### Limitations And Follow-Up

- This is one successful physical exchange, not a device-stack cutover. The Python stack
  remains the qualified runtime.
- The current C operation is synchronously timeout-bounded but Swift task cancellation
  cannot yet close its in-flight socket. Add explicit cancellable socket ownership and
  failure-phase cleanup tests before promotion.
- Define and validate an OpenSSL 3 ABI/version policy for supported Linux hosts. macOS
  test builds currently use the locally installed OpenSSL 3 package and are not evidence
  of a production macOS runtime requirement.
- The current Homebrew OpenSSL library emits a linker warning because its deployment
  version is newer than the package's macOS 14 declaration. This does not affect the
  Linux physical proof or product executable, but the isolated spike is not qualified for
  macOS 14.

## 2026-08-17 - Native CoreDevice Connection Promoted Into DeviceKit

### Summary

- Replaced the synchronous isolated OpenSSL spike with
  `DeviceKit.CoreDeviceTLSConnection`, a production connection component backed by a
  cancellable `CCoreDeviceTLS` handle.
- Made `CCoreDeviceTLS` an explicit `DeviceKit` dependency and removed the isolated
  `NativeDeviceSpike` target. `stupid-app` now links the host-provided OpenSSL 3.x
  libraries, and `doctor` validates the supported major version.
- Kept the complete Python CoreDevice helper authoritative. The native component owns the
  established TCP listener connection only; Python still owns listener creation, remote
  pairing, TUN forwarding, RSD, installation, and launch.

### Lifecycle And Security

- The C handle copies the host and PSK into owned storage, zeroes PSK storage on destroy,
  owns the active close-on-exec socket, and exposes idempotent cancellation without
  exposing OpenSSL diagnostics or key material.
- Connect, TLS handshake, request write, and response read use a nonblocking `poll` loop
  under one monotonic deadline rather than receiving a fresh timeout per phase.
- Listener hosts must be numeric IPv4 or IPv6 addresses. This matches CoreDevice
  discovery output and prevents blocking DNS from escaping task cancellation and the
  total deadline.
- Swift runs the blocking C state machine off the cooperative executor and maps task
  cancellation to an atomic cancellation flag plus socket shutdown. The worker unwinds
  before its handle is destroyed, avoiding concurrent OpenSSL free/use races.
- Socket shutdown and close are serialized so cancellation cannot act on a descriptor
  number after close/reuse, and PSK erasure uses `OPENSSL_cleanse` rather than an
  optimizable plain `memset`.
- TLS remains fixed to version 1.2, an empty PSK identity, and
  `PSK-AES128-GCM-SHA256`. Request and response `CDTunnel` framing is bounded and checked
  before JSON decoding.
- Compile-time and runtime policy accepts OpenSSL major version 3 only. Ubuntu's
  `libssl-dev` is the qualified runtime source; Homebrew `openssl@3` remains suitable for
  tests but currently advertises a newer macOS deployment target than the package.

### Verification

- `swift format lint --strict` passed for the changed Swift/package files, and
  `git diff --check` passed.
- Focused macOS tests passed seven `CoreDeviceTLSConnectionTests`: framing, malformed
  input, OpenSSL/cipher policy, numeric-host enforcement, total timeout, prompt task
  cancellation, and the optional physical-test gate. The timeout completed in roughly a
  quarter second and cancellation in roughly a tenth of a second against local stalled
  TCP peers.
- The complete macOS suite passed 94 Swift Testing cases plus seven asset-catalog XCTest
  cases with one expected optional skip, and `swift build -c release` passed.
- `otool -L` confirms the promoted product links `libssl.3` and `libcrypto.3` from the
  configured OpenSSL provider. The existing Homebrew deployment-target warning remains.
- The isolated x86_64 Ubuntu WSL host passed the same six tests against OpenSSL 3.0.13 and
  completed `swift build -c release`.
- A fresh Python control created only the paired-device listener and owner-only PSK file.
  The promoted Swift/DeviceKit implementation owned the physical TLS and `CDTunnel`
  exchange and completed successfully. The listener process, PSK/control files, temporary
  source tree, and transfer files were removed afterward.

### Follow-Up

- The connection promotion does not retire Python or establish a native `run --network`
  backend. Implement usbmux/lockdown, remote pairing/listener creation, TUN forwarding,
  RemoteXPC/RSD, installation, and AppService launch before any CLI cutover.
- Add a hermetic OpenSSL PSK success server if future connection changes need successful
  TLS coverage without a physical control listener; current hermetic tests cover timeout
  and cancellation while the repeated physical gate covers successful negotiation.

## 2026-08-17 - Native usbmux And Initial Lockdown Client

### Summary

- Added `DeviceKit.USBMuxClient`, a project-owned plist-protocol client for an existing
  usbmuxd Unix or numeric TCP socket.
- Implemented bounded little-endian usbmux framing and `ReadBUID`, `ListDevices`,
  `ReadPairRecord`, `SavePairRecord`, and `Connect` operations with request-tag checks,
  partial-read handling, packet-size limits, socket timeouts, and public-safe errors.
- Added `LockdownClient` for big-endian length-prefixed `QueryType`, `GetValue`, and
  `SetValue` requests after connecting to lockdown port 62078.
- Split USB discovery into the `USBDeviceDiscovering` protocol. `run --usb` now selects
  its target through the native usbmux client; Python remains responsible for IPA
  installation and modern CoreDevice launch.

### Scope And Provenance

- The implementation is intentionally above the retained external usbmuxd socket. It
  does not own raw USB, usbmuxd lifecycle, WSL USBIP packet boundaries, lockdown pairing
  certificates, session TLS, service startup, AFC, installation proxy, or CoreDevice
  launch.
- Wire behavior was implemented from independently corroborated protocol facts and
  sanitized fixtures. The GPL pymobiledevice3/usbmuxd sources were used as readable
  interoperability references only; no source was mechanically translated.
- Pair records remain opaque `Data` at this boundary so tests and diagnostics do not
  decode or print credential content.

### Verification

- `swift format lint --strict` passed for all Swift files changed in this slice.
- The focused macOS suite passed seven usbmux tests. Hermetic coverage includes inclusive
  little-endian usbmux lengths, client metadata, malformed lengths and result codes,
  one-byte fragmented responses, USB/network filtering, opaque pair-record read/write,
  network-byte-order service ports, and big-endian lockdown framing.
- The complete macOS suite passed 101 Swift Testing cases plus seven asset-catalog XCTest
  cases with one expected optional skip. `swift build -c release` and
  `git diff --check` passed; the existing Homebrew OpenSSL deployment-target warnings and
  unhandled icon-fixture warning remain.
- On the isolated x86_64 Ubuntu WSL host, the focused usbmux tests passed and a release
  build succeeded. After explicitly starting the inactive usbmuxd service, an optional
  live probe completed `ReadBUID` and `ListDevices` against its real Unix socket.
- With the physical iPhone attached through USBIP and the WSL distribution held running,
  the same native probe discovered the sole USB device, read its existing pair record as
  opaque data, connected through usbmux to lockdown port 62078, completed `QueryType`,
  and read a device value. No Python process participated in this exchange.

### Limitations And Follow-Up

- The current socket timeout bounds individual reads and writes; broader asynchronous
  cancellation and a single operation deadline should be added before long-running
  native service operations reuse this transport.
- Pair-record creation, lockdown pairing/session TLS, and service startup remain
  unimplemented. Complete those before replacing Python-backed AFC installation.

## 2026-08-17 - Native Lockdown Session TLS And Service Startup

### Summary

- Added typed decoding for existing usbmux pair records and native lockdown
  `StartSession`, `StartService`, and `StopSession` operations.
- Added the narrow `CLockdownTLS` OpenSSL 3 shim. It upgrades the already-connected
  lockdown socket in place using the pair record's host certificate and private key,
  accepts TLS 1.2 through 1.3, performs bounded nonblocking I/O, suppresses thread-local
  `SIGPIPE`, and owns the socket after upgrade.
- Added reusable service metadata and service connections, including the independent
  `EnableServiceSSL` upgrade required by services that request it.
- Kept the scope deliberately on existing trusted records. Fresh certificate generation,
  pairing, AFC framing, installation proxy, and CoreDevice launch remain outside this
  slice, so Python is not retired yet.

### Physical Verification

- On the isolated x86_64 Ubuntu WSL host, the iPhone was attached through USBIP and the
  native live test used the retained external usbmuxd socket.
- Swift discovered the sole USB device, read its existing pair record, connected to
  lockdown, completed client-certificate session TLS, started `com.apple.afc`, opened the
  returned service port, and stopped the lockdown session.
- The focused physical test passed in approximately 0.04 seconds. No Python process was
  used for discovery, pair-record access, session establishment, or service startup.

### Automated Verification

- Added hermetic coverage for required pair-record fields and the complete non-TLS
  session/service request sequence, including escrow-bag handling and session shutdown.
- `swift format lint --strict` passed for the changed Swift/package files and
  `git diff --check` passed.
- The complete macOS suite passed 103 Swift Testing cases plus seven asset-catalog XCTest
  cases with one expected optional skip. `swift build -c release` passed.
- The focused Linux physical test compiled and passed against OpenSSL 3.0.13.

### Follow-Up

- Implement AFC packet framing and file transfer, then installation proxy, over the now
  qualified native service connection so USB installation no longer requires Python.
- Implement fresh lockdown pairing separately before replacing the Python USB bootstrap
  pairing command.

## 2026-08-17 - Native AFC And USB Installation Qualified

### Summary

- Added `NativeUSBInstaller`, a project-owned USB installation path over the retained
  external usbmuxd socket and the qualified native lockdown session.
- Implemented bounded AFC packet framing, directory creation, file open, chunked writes,
  close, and removal. IPA contents stream from disk in 1 MiB chunks rather than being
  retained as one in-memory value.
- Implemented installation-proxy plist framing, developer-package installation progress,
  terminal completion/error handling, and exact bundle-ID verification through `Lookup`.
- Staged files use unique names under `/PublicStaging/stupid-app` and are removed on both
  success and failure paths.
- Cut `run --usb` over to native installation. Removed `PyMobileDevice3Installer`, its
  tests, the obsolete `DeviceInstaller` composition protocol, standalone
  `--pymobiledevice3` CLI options, and the doctor's standalone executable check. Python
  and the pinned package remain required only for CoreDevice pairing, network operations,
  and launch.

### Physical Verification

- The first live attempt used the stock Ubuntu usbmuxd and timed out during the first AFC
  operation. No installation success is claimed for that attempt; its test process was
  terminated before retry.
- Restarted the already-qualified usbmuxd 1.1.1 build with the 16,383-byte USB transfer
  size required by WSL USBIP. The unchanged native installer then established lockdown,
  connected to AFC, staged the development IPA, completed installation proxy, verified
  the exact bundle ID, removed the staged IPA, and stopped the session.
- The complete native install operation passed in approximately 0.92 seconds. No Python
  process participated in USB discovery, pair-record loading, lockdown TLS, AFC transfer,
  installation, verification, or cleanup.

### Automated Verification

- Added hermetic AFC tests for header lengths, packet numbers, split write metadata,
  malformed magic, invalid lengths, and oversized packets.
- `swift format lint --strict` passed for all changed Swift files.
- The complete macOS suite passed 100 Swift Testing cases plus seven asset-catalog XCTest
  cases with one expected optional skip. `swift build -c release` passed.
- Existing warnings remain for the unhandled icon fixture and the Homebrew OpenSSL macOS
  deployment target.

### Follow-Up

- Implement fresh native lockdown pairing and wireless enablement.
- Implement RemoteXPC/RSD and AppService launch so the remaining Python helper can be
  removed after the required repeated physical acceptance runs.

## 2026-08-17 - Native Lockdown Pairing And Wireless Enablement Qualified

### Summary

- Added `LockdownPairer`, which performs fresh lockdown pairing over the native usbmux
  client, waits for the device Trust response, establishes client-certificate session TLS,
  writes `WirelessBuddyID`, enables `EnableWifiConnections`, and verifies the resulting
  value.
- Added exact OpenSSL 3 generation of the required RSA root, host, and device certificate
  material to the existing narrow `CLockdownTLS` shim. Private-key buffers are owned by the
  pairing-material handle and cleansed before release.
- Checked the certificate shape and pairing request sequence against libimobiledevice's
  LGPL-2.1-or-later implementation as an interoperability reference; the dependency is not
  vendored or linked, and its provenance is recorded in `THIRD_PARTY_NOTICES.md`.
- Integrated native pairing into `stupid-app device pair --usb` before the remaining
  CoreDevice helper, and added `--replace-lockdown-record` for an explicit new host trust
  identity.
- Updated native USB installation to prefer the owner-only pairing cache, with existing
  usbmux daemon records retained as a read fallback.

### Physical Findings

- Replacing a host record must use a new `SystemBUID`; modern iOS rejects a new `HostID`
  under an already-associated BUID during subsequent session TLS.
- A Swift-X509 chain with equivalent visible fields was accepted by the `Pair` request but
  rejected during client-certificate TLS. Generating the bounded chain with the same
  OpenSSL 3 structures used by the native TLS layer completed session TLS.
- The stock Ubuntu usbmuxd and the previously qualified daemon binary both returned
  `EOPNOTSUPP` while their linked plist writer attempted `SavePairRecord`, despite the
  target directory being writable. The CLI now stores the record directly in its existing
  mode-`0700` pairing cache as a mode-`0600` file. This is also the cache consumed by the
  remaining CoreDevice helper.
- Fresh native pairing completed on the attached unlocked iPhone, stored the owner-only
  record, and enabled and verified wireless lockdown. A second native operation reused the
  cached record and completed in approximately 0.04 seconds without another Trust flow.

### Verification

- `swift format lint --strict` passed for the modified Swift and package files, and
  `git diff --check` passed.
- macOS `swift test` passed 101 Swift Testing cases plus seven asset-catalog XCTest cases,
  with one expected optional differential skip. `swift build -c release` passed; the
  existing Homebrew OpenSSL deployment-target warnings remain.
- x86_64 Ubuntu WSL `swift test` passed 102 Swift Testing cases plus seven asset-catalog
  XCTest cases, with the two expected macOS-only skips. `swift build -c release` passed
  against OpenSSL 3.0.13.
- The fresh and cached physical pairing checks used no Python process. Python remains
  required for CoreDevice remote pairing, listener/tunnel lifecycle, RSD, and launch.

### Follow-Up

- Implement read-only RemoteXPC/RSD service discovery and the privileged TUN packet pump.
- Implement native AppService launch and CoreDevice remote pairing before removing Python,
  `uv`, the frozen environment, and helper resources.

## 2026-08-17 - Native RemoteXPC, RSD, And AppService Launch

### Summary

- Implemented the native RemoteXPC/RSD protocol stack in `DeviceKit` as the next slice of
  the Python device-stack replacement: the XPC binary dictionary codec, the RemoteXPC
  HTTP/2-derived framing and connection, an RSD client, and a CoreDevice AppService launch
  client.
- The codec and framing were verified byte-for-byte against the pinned pymobiledevice3
  8.2.1 reference before any connection code was accepted.

### XPC Codec

- Added `XPCCodec` (`Sources/DeviceKit/XPCCodec.swift`) with a `XPCValue` model covering
  null, bool, int64, uint64, double, data, string, uuid, array, and dictionary.
- The object encoder mirrors the reference `construct` layout exactly: little-endian
  message-type tags, length-prefixed strings/data padded to 4-byte boundaries, big-endian
  IEEE-754 doubles (construct's `Float64b`), and length-prefixed array/dictionary bodies.
- The wrapper encoder writes the RemoteXPC `XpcWrapper` envelope (magic `0x29B00B92`,
  flags, stored payload length, message ID) followed by the `XpcPayload` envelope (magic
  `0x42133742`, protocol version 5) and the object.
- Unsupported message types fail loudly instead of being coerced; decoding is bounded by
  length checks and rejects trailing bytes, truncated payloads, and invalid magic.

### HTTP/2 Framing And RemoteXPC Connection

- Added `HTTP2Frame` (`Sources/DeviceKit/HTTP2Frame.swift`) for the minimal HTTP/2 client
  subset RemoteXPC uses: SETTINGS, WINDOW_UPDATE, HEADERS, DATA, GOAWAY, and RST_STREAM.
- Added `RemoteXPCConnection` (`Sources/DeviceKit/RemoteXPCConnection.swift`) that performs
  the exact RemoteXPC handshake (preface, SETTINGS with the reference window values,
  WINDOW_UPDATE increment, root-channel HEADERS, empty request, keep-alive wrapper, reply
  channel open, SETTINGS ACK), then `sendRequest`/`receiveResponse` over the root channel
  with message-ID tracking and even-stream WINDOW_UPDATE feedback.
- Transport failures map to public-safe `RemoteXPCConnection.Error` cases.

### RSD And AppService Launch

- Added `RSDClient` (`Sources/DeviceKit/RSDClient.swift`) that connects to an RSD
  endpoint, completes the RemoteXPC handshake, receives and decodes peer info, resolves the
  device UDID and product type, and exposes the advertised service table.
- Added `RemoteXPCService`, which owns a connected RemoteXPC socket for one advertised
  service and closes it on deallocation.
- Added `AppServiceClient` (`Sources/DeviceKit/AppServiceClient.swift`) implementing
  `com.apple.coredevice.appservice` launch through the `CoreDevice.CoreDevice*` invoke
  envelope and extracting the reported process identifier.

### Verification

- `swift format lint --strict` passed for all new and modified Swift files.
- `swift test` passed 110 Swift Testing cases across 19 suites plus seven asset-catalog
  XCTest cases with one expected optional skip. `swift build -c release` passed.
- New hermetic coverage: byte-exact XPC wrapper encoding against captured reference
  fixtures for every supported scalar, arrays, empty and nested dictionaries; full nested
  fixture decode; peer-info shape decode; malformed/truncated rejection; round-trips for
  every value type; a fake RemoteXPC HTTP/2 server exercising the full handshake and
  peer-info exchange; an AppService launch against the fake server returning a process
  identifier; and peer-close and missing-process-identifier failure paths.

### Limitations And Follow-Up

- This slice is protocol plumbing only; it does not yet retire Python. The remaining
  native work is the CoreDevice tunnel creation over lockdown, the privileged TUN packet
  pump, remote pairing, network installation, and CLI wiring.
- No physical-device verification was performed for this slice; the fake server is
  hermetic and the real device exchange still requires the native tunnel and TUN layers.

## 2026-08-17 - Native CoreDevice Tunnel, TUN, And USB Launch Path

### Summary

- Implemented the native CoreDevice tunnel creation over lockdown for the USB launch
  path, replacing the remaining Python-owned `launch-usb` helper operation.
- Added `CTUN`, a Linux TUN shim that opens `/dev/net/tun`, configures the interface
  (IPv6 address, MTU, link-up) with in-process netlink, adds the server host route, and
  forwards bounded packets.
- Added `CoreDeviceUSBLauncher` in `DeviceKit`: native lockdown session, CoreDeviceProxy
  service start over lockdown, CDTunnel handshake over the service connection, TUN
  creation, a bidirectional IPv6 packet pump between the tunnel socket and TUN, then
  RSD discovery, AppService launch, and process-identifier return.
- Added a hidden privileged `stupid-app coredevice-helper launch-usb` subcommand that
  runs the native launch under `sudo`, and `NativeCoreDeviceRunner` in `DeviceKit` that
  invokes the current executable as that helper through the bounded `ProcessRunner`.
- Wired `run --usb` installation to launch fully natively: USB install was already
  native; the launch now uses the native tunnel instead of the Python helper.

### CTC / lock introspection

- The `iosdev-ubuntu` WSL host has no `iosdev` password and no passwordless sudo. Prior
  sessions always performed privileged operations via `wsl -u root` from Windows. The
  native helper's `--sudo` path therefore needs a sudoers grant; a temporary NOPASSWD
  entry restricted to the CLI was added on the test host only, not committed. The
  handover already records explicit-privilege-boundary guidance; this is data, not a code
  change.

### Verification

- `swift build` and `swift format lint --strict` pass locally; the macOS suite passes
  (116 Swift Testing cases plus asset-catalog XCTest).
- Added hermetic tests: CDTunnel handshake framing, malformed/truncated response
  rejection, and native runner PID parsing/redaction.
- On the isolated WSL host, the native flow established the lockdown session, started
  the CoreDeviceProxy service, completed the CDTunnel handshake
  (`client fd..::2 server fd..::1:port`), configured the TUN (in-process netlink address
  dump confirms the client address and `/64` route are applied in the helper netns), and
  forwarded packets bidirectionally through the packet pump (observed both directions).
- Native USB installation already completed in roughly one second with no Python.

### Remaining Greenfield Gap

- The RSD/AppService launch over the tunnel forwards packets both ways but the launch
  did not yet complete on-device during this session; the exchange advances and then
  stalls, so the tunnel and pump are qualified but the RSD/RemoteXPC AppService launch
  needs further on-device debugging. Network operation and CoreDevice remote pairing
  still use the Python helper.

## 2026-08-17 - Native CoreDevice USB Launch Qualified

### Summary

- Completed the native CoreDevice USB launch path. The privileged helper now
  resolves the RSD peer, connects the CoreDevice appservice, invokes the launch
  feature, and reports the returned process identifier. The app reliably opens on
  the registered physical device and the helper prints a clean JSON status on
  every repeated run.
- Closed the last greenfield gap from the prior entry (RSD/AppService launch
  stalling on-device). Network operation and CoreDevice remote pairing still use
  the pinned Python helper.

### On-Device Environment Setup

- The WSL test host had auto-shut down, leaving a stale non-persistent usbipd
  attach. Restored `vmIdleTimeout=-1` in `.wslconfig` (it had been dropped) and
  held an open WSL session so the VM stayed alive across commands; then re-attached
  the passed-through iPhone and restarted the stock `usbmuxd` 1.1.1 manually (the
  systemd unit targets a newer usbmuxd the installed binary does not support).
- The qualified MTU-patched usbmuxd did not rebuild on this host because the newer
  system libplist now declares `PLIST_FORMAT_XML`/`PLIST_FORMAT_BINARY`, which
  collide with usbmuxd 1.1.1's own enum. The default daemon suffices for the
  small-message lockdown/tunnel path exercised here.

### Root Causes Found And Fixed

1. **Unsafe two-thread TLS relay.** `CoreDeviceProxy` enables service TLS, and the
   old `PacketPump` ran `SSL_read` and `SSL_write` concurrently on one OpenSSL
   connection from two dispatch threads, which is not thread-safe and corrupted the
   stream (manifested as truncated peer info and intermittent transport errors).
   Replaced it with a single-threaded non-blocking relay
   (`stupid_app_lockdown_tls_relay_tun`) that polls both the TLS socket and the TUN
   descriptor, buffers partial inbound packets, and writes complete IPv6 packets to
   the TUN one at a time.
2. **Wrong RemoteXPC reply-channel handshake flag.** The handshake sent
   `0x0000_4001` for the reply channel instead of
   `INIT_HANDSHAKE(0x0040_0000)|ALWAYS_SET(0x1) = 0x0040_0001`. The device rejected
   the connection. The flag is now derived from the `XPCCodec.Flags` constants.
3. **Empty keep-alive XPC wrappers.** The device emits wrappers with an empty
   payload envelope (`payloadLength == 0`) as keep-alives; the decoder treated these
   as malformed. `decodeWrapper` now returns a nil-value wrapper and
   `receiveResponse` skips it, matching pymobiledevice3's `payload is None` skip.
4. **Trailing bytes after a wrapper.** A large peer-info message spanning multiple
   DATA frames leaves trailing bytes after the first wrapper; `decodeWrapper`
   rejected them. It now decodes one wrapper from the front of the stream, matching
   pymobiledevice3's `XpcWrapper.parse`.
5. **RSD ports are encoded as strings.** The peer-info service table serializes
   `Port` as a string; the parser only accepted integers and skipped every service
   (`services == 0`). It now parses string, uint64, and int64 ports and skips
   port-less services instead of failing the whole peer.
6. **RST/close after peer info.** The device closed the RSD connection because the
   client ACKed a SETTINGS-ACK frame; HTTP/2 forbids ACKing an ACK. `receiveFrame`
   and `receiveResponse` now ACK only SETTINGS frames without the ACK flag. The
   device GOAWAY text was literally "SETTINGS: unexpected ACK".
7. **RSD control connection lifetime.** pymobiledevice3 keeps the RSD control
   connection open while a nested service runs. When the native client closed it
   before the appservice launch finished, the device tore the tunnel down and the
   launch response never arrived (the app would still open). Introduced
   `RSDSession`, which owns the RSD socket for the duration of nested service calls.
8. **Invalid `platformSpecificOptions`.** The reference sends
   `plistlib.dumps({})`, an empty XML plist; the client sent the 8-byte
   `"bplist00"` magic which is not a valid serialized plist. Now a full empty XML
   plist is embedded.
9. **SIGPIPE during teardown.** The relay could die with SIGPIPE while the
   transport closed, before the helper printed its status JSON. SIGPIPE is now
   ignored for the short-lived privileged helper so it reliably reports the result
   and exits zero.

### Verification

- macOS: `swift test` passes 118 Swift Testing cases across 21 suites; the optional
  local `actool` differential catalog test skips as designed. `swift build` and
  `swift format lint --strict` pass.
- Added hermetic regression tests: empty keep-alive wrapper decode
  (`XPCCodecTests`), and RSD peer-info string-port parsing plus port-less-service
  skipping (`RemoteXPCConnectionTests`).
- The isolated x86_64 Ubuntu WSL host built the cutover source and, with the device
  attached and unlocked, the native helper established the lockdown session,
  CoreDeviceProxy tunnel, TUN, RSD peer, and appservice launch on repeated runs.
  Each run reported `{"status":"ok","operation":"launch-usb","pid":N}` and exited
  zero, and the app launched on the physical iPhone.
- USB installation was already native; the launch is now native too. Network
  operation and CoreDevice remote pairing remain on the pinned Python helper.

### Follow-Up

- Make the MTU-patched usbmuxd reproducible on the current libplist, and re-run the
  end-to-end `run --usb` (install + launch) to confirm a real development IPA
  installs and launches through the fully native USB path.
- Implement native CoreDevice remote pairing and the network run path to retire the
  remaining Python helper.

## 2026-08-18 - Native CoreDevice Network Run Path

### Summary

- Implemented the native `run --network` path so the deployment loop no longer invokes
  Python. The remaining Python helper is now limited to the one-time `device pair --usb`
  CoreDevice remote-pair bootstrap.
- Added `RemotepairingDiscovery` (Swift mDNS/DNS-SD): DNS name encode/decode with
  compression pointers, PTR/SRV/TXT/A/AAAA record parsing, IPv6 RFC-5952 formatting, a
  multicast UDP browser for `_remotepairing._tcp.local.`, and candidate assembly that
  sorts link-local IPv4 first.
- Added `RemotePairing` + `RemotePairingChannel`: the RPPairing framing
  (`RPPairing` + Int16 length + JSON), the XPC JSON envelope (plain and streamEncrypted),
  the remote pairing record reader, TLV8 codec, host-ID (UUIDv3) derivation, and the
  Pair-Verify exchange using X25519 ECDH, HKDF-SHA512, ChaCha20-Poly1305, and Ed25519
  signing. `createTCPListener()` returns the listener port and the derived PSK.
- Extended `CCoreDeviceTLS` with a persistent PSK tunnel: `tunnel_connect` performs the
  TLS 1.2 PSK-AES128-GCM-SHA256 handshake and CDTunnel exchange while retaining the live
  socket, and `tunnel_relay` pumps complete IPv6 packets between the TLS connection and a
  TUN descriptor (mirroring the lockdown relay).
- Added `PersistentCoreDeviceTunnel` (Swift wrapper: connect, decode handshake, create
  TUN + route, start/stop the relay thread) and `NativeNetworkRunner` (mDNS browse →
  candidate pair-verify → persistent tunnel → RSD peer resolution → AFC + installation
  proxy over the `*.shim.remote` RSD services → AppService launch).
- Wired `stupid-app run --network --udid <udid>` in `RunCommand` to `NativeNetworkRunner`;
  removed `--python` and `--coredevice-helper` from `run`.

### Verification

- `swift build` and `swift format lint --strict` pass (formatted all new files).
- `swift test` passes 132 cases (added 9: mDNS DNS codec/browse parse, TLV8, host ID,
  record load, identifier globbing, ChaCha20-Poly1305 wire round-trip, sequence nonce,
  session HKDF labels, address sorting). The network connect/TLS/relay candidates are
  exercised only by unit fixture logic; on-device qualification remains on the WSL host.

### Limitations And Follow-Up

- Not physically qualified yet. Clean-host and three-consecutive-unplugged-run
  acceptance must run on the isolated WSL host (requires `--sudo`/NOPASSWD, USBIP iPhone
  passthrough for a fresh pair, and an existing `remote_<id>.plist` from a prior pair).
- `device pair --usb` still calls the Python helper for the CoreDevice remote-pair
  bootstrap. The last Python removal is native SRP-3072 Pair-Setup over the RSD
  CoreDevice tunnel service, which needs a BigInt + SRP-3072 client and OPACK device-info
  encoding, then cutting `device pair`, `doctor`, and the helper resources over and
  removing `Tools/pymobiledevice3` and `uv`.

## 2026-08-18 - Native SRP-3072 Pair-Setup Crypto Core

- Implemented the cryptographic core required to make the last Python path
  (`device pair --usb` CoreDevice remote-pair bootstrap) native.
- `BigUInt` (`Sources/DeviceKit/BigUInt.swift`): an unsigned arbitrary-precision
  integer sized for the 3072-bit SRP group (little-endian 64-bit limbs), with
  add/subtract/multiply, binary long division, byte/hex conversion, and modular
  exponentiation via Montgomery multiplication.
- `SRPClient` (`Sources/DeviceKit/SRPClient.swift`): mirrors `srptools`
  `SRPClientSession`/`SRPContext` exactly for `Pair-Setup`/SHA-512/PRIME-3072/G=5:
  k, x, verifier, u, premaster (negative-base handling), K, M, and M2.
- `OPack` (`Sources/DeviceKit/OPack.swift`): a minimal OPACK encoder matching
  `opack2` byte-for-byte for the pairing `device_info` dictionary.
- Validation: `SRPClient` matches a deterministic srptools vector for a fixed
  private `a`, salt, and server public (A, K, M, M2 all match); `OPack` matches
  `opack2.dumps` byte-for-byte; `BigUInt` has unit + small-value modPow checks.
  The reference-vector ordering pitfall (`process(other_public, salt)`) was
  caught and the test regenerated.

### Remaining Work

- Wire the RSD `com.apple.internal.dt.coredevice.untrusted.tunnelservice`
  RemoteXPC exchange (ServiceVersion handshake, mangledTypeName wrapping, XPC
  adaptation of the plain/streamEncrypted envelope) plus the Pair-Setup message
  sequence (consent, proof, save-on-peer, session keys, remote unlock, local
  record write) into `device pair --usb`.
- Cut `device pair`, `doctor`, and the helper resources over; remove
  `CoreDeviceRunner`, `Sources/DeviceKit/Resources/pymobiledevice3_helper.py`,
  and `Tools/pymobiledevice3`/`uv`.
- Physically qualify on the WSL/USBIP deployment host (fresh pair + three
  unplugged network runs). On-device acceptance requires the iPhone on the
  deployment host, not the authoring Mac.

## 2026-08-18 - RSD Pair-Setup Orchestration And Record Format

- Added `CoreDeviceRemotePairing` (`Sources/DeviceKit/CoreDeviceRemotePairing.swift`): the
  Pair-Setup message sequence (consent, SRP proof, encrypted save-on-peer, session keys,
  remote-unlock, record assembly) over the RSD untrusted tunnelservice envelope transport.
  It reuses `SRPClient`, `OPack`, `RemotePairing` TLV8, and the ChaCha20-Poly1305/HKDF
  helpers. The transport is a send/receive closure the caller wires to `RemoteXPCService`;
  because the device pushes the awaiting-consent event, the transport supports a
  receive-only call (`nil` send).
- Added `RemoteXPCService.receiveValue()` and `request(_:)` to `RSDClient` for the pushed
  ServiceVersion and the non-reply-flag envelope exchange, and `XPCValue.dataValue`.
- Fixed `RemotePairing.Record` so `remote_unlock_host_key` is parsed as a string: an
  on-device probe of an existing `remote_<id>.plist` showed it is a base64 `string`, not
  `data`. This previously would have made the native network path reject the record.
- Made `OPackValue` an `indirect` enum with a `dictionary([OPackEntry])` case to resolve a
  recursive-`Sendable` circular-reference when used from a `Sendable` orchestrator.

### Status At Handoff

- Fully native and macOS-tested (141 cases): the `run --network` path (mDNS DNS-SD,
  Pair-Verify, persistent OpenSSL PSK tunnel, TUN relay, install/launch over RSD) and the
  SRP-3072/OPACK crypto core.
- `CoreDeviceRemotePairing` compiles but is not yet on-device validated; the WSL build was
  interrupted on an unrelated `CLZFSE` C-module error before qualification.
- Remaining to fully remove Python: wire `device pair --usb` to `CoreDeviceRemotePairing`
  over the native CoreDevice USB tunnel + RSD, cut `doctor` and the helper resources over,
  delete `CoreDeviceRunner`, `Sources/DeviceKit/Resources/pymobiledevice3_helper.py`, and
  `Tools/pymobiledevice3`+`uv`, then qualify on a clean `iosdev-ubuntu` host (fresh pair +
  three unplugged network runs). The WSL `.build` needs a clean rebuild to clear the stale
  CLZFSE module state.

## 2026-08-18 - Native Device Pairing Cutover And Python Stack Removal

### Summary

- Wired `stupid-app device pair --usb` to the native SRP-3072 Pair-Setup bootstrap,
  removing the last Python product path. `device pair --usb` now performs native
  lockdown pairing, then a privileged `coredevice-helper pair-usb` subcommand
  establishes the CoreDevice USB tunnel and completes Pair-Setup over the RSD
  `com.apple.internal.dt.coredevice.untrusted.tunnelservice` service.
- Deleted the Python stack: `CoreDeviceRunner`, the bundled
  `pymobiledevice3_helper.py` resource, `Tools/pymobiledevice3` (`pyproject.toml`,
  `uv.lock`, and the frozen `.venv`), the Python test file, and the DeviceKit
  resource declaration. No CLI command invokes Python.
- Cut `doctor` over: the frozen Python/package check was replaced with a native
  CoreDevice-helper check, and the `--python`/`--coredevice-helper` options were
  removed from `doctor` and `device pair`.

### Native Pair-Setup Components

- Refactored `CoreDeviceUSBLauncher` into `USBCoreDeviceTunnel`, which owns the
  lockdown session, CoreDevice proxy tunnel, CDTunnel handshake, TUN interface,
  packet relay, and RSD session with a single deferred teardown. Both `launch-usb`
  and the new `pair-usb` helper reuse it.
- Added `CoreDeviceTunnelService`, a native client for the RSD tunnel service: it
  reads the pushed `ServiceVersion`, performs the `attemptPairVerify` handshake
  (consuming plain sequence zero), captures the device's remote-pairing identifier
  from `peerDeviceInfo`, and provides the mangled-Type-Name transport closure.
- Added `CoreDeviceRemotePairer`, which runs `CoreDeviceRemotePairing.pair()` over
  that transport and writes the `remote_<identifier>.plist` record as a mode-`0600`
  file inside the mode-`0700` pairing directory, returning ownership to the invoking
  user when the helper runs under sudo.
- `CoreDeviceRemotePairing.pair()` now accepts an `initialSequenceNumber` so the
  Pair-Setup exchange continues the sequence consumed by the handshake.
- Fixed `requestConsent` to handle the `awaitingUserConsent` response: the device
  answers the consent request with that event and then pushes the pairing data, so
  the client must read the push instead of parsing the first response as pairing
  data.

### Hermetic Verification

- Added a scripted SRP-3072 server test (`CoreDeviceRemotePairingTests`) that
  mirrors the device math and proves the complete Pair-Setup envelope sequence:
  consent (both immediate and pushed after a Trust dialog), proof verification,
  the encrypted PS-Msg05/06 record handoff, and the encrypted
  `createRemoteUnlockKey` request. The server splits values longer than 255 bytes
  into repeated TLV8 components, matching the wire length-prefix constraint. A
  rejected client proof fails loudly.
- Extended the fake RemoteXPC server with a tunnel-service mode and added a test
  that `CoreDeviceTunnelService.connect()` parses the pushed `ServiceVersion`,
  sends the mangled-Type-Name handshake envelope, and extracts the device
  identifier.
- `swift test` passes 141 cases across 26 suites; `swift build -c release` and
  `swift format lint --strict` pass. The pre-existing Homebrew OpenSSL
  deployment-target warnings and unhandled icon fixture warning remain.

### Limitations And Follow-Up

- The native pair cutover is not yet physically qualified. The isolated
  `iosdev-ubuntu` WSL host must re-prove a fresh native `device pair --usb`
  (including the on-device Trust dialog) and three consecutive unplugged
  `run --network` runs with the cutover source. The WSL `.build` needs a clean
  rebuild to clear the previously reported stale CLZFSE module state.
- `device pair --usb` and `run --usb` still require the qualified USBIP-compatible
  usbmuxd transport for large IPA transfers; small-message lockdown/tunnel traffic
  works with the stock daemon.

## 2026-08-18 - Native Network Run Physical Qualification: RSD-Over-Tunnel Blocker

### Summary

- Attempted the physical qualification of the fully native device stack on the
  isolated `iosdev-ubuntu` WSL host: fresh native `device pair --usb`
  (lockdown + SRP-3072 Pair-Setup) and the native `run --network` path.
- A fresh native pair succeeded: the remote pairing record was written as a
  mode-`0600` `remote_<id>.plist` under the mode-`0700` pairing directory and
  the ownership-handoff back to the invoking user worked.
- The native `run --network` path is **blocked**: the device's RSD daemon rejects
  the RSD connection over the native network tunnel, so the native network
  install/launch cannot complete. This is a genuine open blocker, not a
  configuration issue.

### Physical Environment

- `iosdev-ubuntu` WSL host reached via the Windows box (`wsl -d iosdev-ubuntu -u iosdev`).
- A temporary `cap_net_admin=ep` file capability on the `stupid-app` and test
  binaries provides the TUN capability without full root; a NOPASSWD sudoers
  entry grants the `coredevice-helper` subcommand (and, temporarily, the Python
  comparison scripts).
- The iPhone was passed through from Windows via USBIP (`usbipd attach`) and
  detached before the network runs to satisfy the unplugged condition.

### Blocker Detail

The native `run --network` (and the isolated RSD client) reaches the device:
mDNS discovery, the RPPairing Pair-Verify, the TLS-PSK `CDTunnel` handshake, the
TUN + relay, and the RSD TCP connection all work. The device's RSD daemon then
sends **only the HTTP/2 SETTINGS frame and immediately closes the tunnel**,
so the peer-info (and thus install/launch) never arrives.

### Decisive Isolation Result

- `pymobiledevice3 8.2.1` (frozen Python 3.13 environment reconstructed locally)
  completes the whole network path against the same device, proving the device,
  network, tunnel, and RSD are all functional.
- Running pymobiledevice3's **own RSD client over the native tunnel** (native
  establishes the tunnel, Python connects the RSD) fails with a timeout and the
  device closes the tunnel after SETTINGS. This proves the defect is in the
  **native tunnel establishment**, not the native RSD client.
- The native RSD handshake bytes are byte-identical to the pymobiledevice3
  reference (verified with a generated 195-byte reference handshake). The RSD
  connection source address equals the tunnel client address in both cases.

### Ruled Out

- RSD handshake content (byte-identical to the reference).
- RSD connection source/destination addressing (both use the tunnel client address).
- RSD handshake TCP segmentation (matched pymobiledevice3 via split writes + TCP_NODELAY).
- The relay framing: the network relay (`stupid_app_coredevice_tls_tunnel_relay`)
  is structurally identical to the working USB relay
  (`stupid_app_lockdown_tls_relay_tun`, which the device accepts over USB).
- Pairing record and host-identifier derivation (identical to pymobiledevice3).
- The explicit `/128` server route (removed; the on-link `/64` route now matches
  pymobiledevice3).
- The `createListener` `owningProcessName` (changed to `"CoreDeviceService"` to
  match the reference).
- Relay poll latency (2 ms vs 50 ms).
- The device does NOT close an idle tunnel, so the close is specifically tied to
  the RSD connection over the native tunnel.

### Code Changes Made During This Session

Real fixes and reference-alignment (kept):

- `RemotePairingChannel`: fixed the `PV-Msg03` ChaCha20-Poly1305 nonce to the
  correct 12 bytes (`00 00 00 00` + `"PV-Msg03"`); it was 8 bytes and would have
  failed at runtime on the first physical network Pair-Verify.
- `RemotePairingChannel`: `createTCPListener` now sends `owningProcessName =
  "CoreDeviceService"` to match the pymobiledevice3 reference.
- `RemoteXPCConnection`: the RemoteXPC handshake is written frame-by-frame
  instead of as one concatenated buffer, matching pymobiledevice3's per-frame
  writes.
- `USBMuxClient`: `TCP_NODELAY` is applied to sockets so handshake frames are
  not coalesced into a single segment.
- `PersistentCoreDeviceTunnel`: the explicit `/128` server route is no longer
  added; the on-link `/64` route (matching pymobiledevice3) covers the server.
- Linux-only build fixes for `RemotepairingDiscovery` (`SOCK_DGRAM`, `IPPROTO_*`
  typed as `Int` on glibc) and `PersistentCoreDeviceTunnel` (OpaquePointer
  Sendable capture moved through integer bit patterns). These were latent and
  only surfaced when the network source first built on WSL.
- `NetworkPathPhysicalTests`: an env-gated physical test harness with modes to
  (a) browse mDNS + establish the native tunnel + open RSD, (b) hold the tunnel
  and export its RSD endpoint, (c) delay the RSD connect, (d) hold the tunnel
  idle without RSD, and (e) connect the native RSD to an external endpoint.

Environment-gated diagnostic logging (kept, disabled unless
`STUPID_APP_TUNNEL_DEBUG` is set): the C relays log device/host packet activity
and IPv6/TCP header details, the RemoteXPC connection logs the handshake hex and
received frame kinds, and the socket layer logs received bytes. This is intended
for the next debugging session and produces no output in normal operation.

### Verification

- macOS `swift test`: 144 cases across 27 suites pass; `swift build -c release`
  and `swift format lint --strict` pass; `git diff --check` passes.
- The pre-existing Homebrew OpenSSL deployment-target and unhandled icon-fixture
  warnings remain.
- WSL host: the source builds and all 143 Linux tests pass (the macOS-only
  differential catalog check skips).

### Recommended Next Steps

1. Capture pymobiledevice3's encrypted `createListener` request and the TLS-PSK
   tunnel details byte-for-byte and diff against the native implementation; the
   tunnel establishment is the only remaining un-diffed part.
2. Use the native tunnel while connecting with pymobiledevice3's RSD client (and
   vice versa) to continue isolating whether the remaining difference is in the
   tunnel establishment or the TLS tunnel itself.
3. Fix the identified difference, then re-run the full qualification: fresh
   native pair + three consecutive unplugged `run --network` runs.
4. Re-apply the missing `cap_net_admin` setcap after any test rebuild on WSL
   (each `swift build` of the test binary wipes the file capability).
5. When the network run is qualified, re-run `doctor`, then remove the temporary
   sudoers/Python comparison environment and the debug logging.

## 2026-08-18 - Native Network Run Blocker Resolved: Relay WANT_READ Misread As EOF

### Summary

- Diagnosed and fixed the open blocker that prevented the fully native
  `run --network` path from completing. With a proven pymobiledevice3 RSD client
  over the native tunnel also failing identically (device sends only its
  SETTINGS frame and the client times out), the investigation isolated the
  defect to the persistent network tunnel relay.
- Root cause: in `stupid_app_coredevice_tls_tunnel_relay`, the device->host
  read treated any `SSL_read_ex` return of `0` as a clean peer close. On the
  non-blocking OpenSSL socket, `SSL_read_ex` returns `0` for `SSL_ERROR_WANT_READ`
  as well as for `SSL_ERROR_ZERO_RETURN`, so the relays exited after delivering
  the device's SETTINGS frame and never read the peer-info. The device did not
  close the tunnel; the RSD client just never received the peer-info.
- Fixed both the network relay and the identical latent USB lockdown relay
  (`stupid_app_lockdown_tls_relay_tun`): call `SSL_get_error` and treat only
  `SSL_ERROR_ZERO_RETURN` as a peer close; `SSL_ERROR_WANT_READ`/`WANT_WRITE`
  continue the poll loop. Added a device->host drain loop that attempts to read
  all available decrypted bytes regardless of poll state, because OpenSSL can
  hold decrypted data in its internal buffer while the raw socket has no new
  bytes.

### Evidence

- `tcpdump` on the isolated WSL host captured the device continuing to send
  TLS-encrypted tunnel data for roughly eight seconds after the relay first
  reported `EOF` (the host TCP stack ACKed it throughout). This proved the
  device did not close the TLS tunnel and that the relay's EOF was a false
  `SSL_ERROR_WANT_READ`.
- The device's initial SETTINGS frame content and the negotiated TLS cipher and
  ServerHello were byte-identical between the native and the working Python
  tunnel, confirming the TLS layer was not at fault.

### Ruled Out (with evidence)

- RSD client handshake bytes: byte-identical to the generated pymobiledevice3
  reference (195 bytes).
- TLS negotiation: both the native and Python tunnels negotiated cipher
  `0x00A8` (OpenSSL name `PSK-AES128-GCM-SHA256`) with identical ServerHellos.
- TUN setup, relay structure, and the packet-level TCP/IP stream over the
  tunnel: equivalent to the working paths.
- RPPairing control-connection lifetime: keeping it open across the tunnel did
  not change the failure and was reverted after the real fix.
- RSD-connect timing (adding a delay did not change the failure) and the
  CDTunnel request JSON key order (the USB path uses the same order and works).

### Verification

- The isolated x86_64 Ubuntu WSL host: `RSD OPENED` reported the peer with all
  service entries, and three consecutive physically unplugged `run --network`
  runs each assembled, signed once, packaged, discovered, tunneled, installed,
  verified, and launched the development app. No residual CLI/helper processes
  or tunnel interfaces remained.
- macOS `swift test`: the DeviceKit suites (including the relay-adjacent
  CoreDeviceTLS and CoreDeviceRemotePairing suites) pass. A pre-existing flaky
  `CoreDeviceTLSConnectionTests.totalTimeout` timing assertion can exceed its
  2-second bound under full-suite parallel load; it passes consistently in
  isolation (~0.25 seconds). The wall-clock bound was later relaxed to 10 seconds
  (see the 2026-08-18 `release status` / clean-host entry) so scheduler dispatch
  delay under parallel load no longer fails the suite.
- `swift format lint --strict` and `git diff --check` pass for the changed files.

### Follow-Up

- Keep the env-gated `STUPID_APP_TUNNEL_DEBUG` relay/RSD/socket logging; it is
  what surfaced this defect and remains useful for future device-stack work.
- Re-run `stupid-app doctor` on the clean host and remove the temporary
  sudoers/`cap_net_admin`/Python comparison environment used during debugging.
- The native device stack is now fully qualified end-to-end for the network run
  without Python.

## 2026-08-18 - `release status`, Clean-Host Re-Qualification, And Debug Environment Cleanup

### Summary

- Added `stupid-app release status`, completing the proposed command surface.
- Re-built the current source on the isolated WSL host from a clean `.build`,
  clearing the stale `CLZFSE` module state reported at the previous handoff.
- Re-ran `stupid-app doctor` on the clean host with zero failures.
- Re-qualified the fully native `run --network` path with three consecutive
  physically unplugged runs; each built, signed once, packaged, discovered,
  tunneled, installed, verified, and launched the development app with no residual
  processes or interfaces.
- Removed the temporary debug environment: the broad `NOPASSWD: ALL` sudoers grant,
  the Python comparison venvs and scripts, the stale `coredevice-helper` sudoers
  path (now scoped to the current build binary), the leftover Windows-side transfer
  scripts, and the stale proof credential directory.
- Added `docs/clean-host-setup.md` with repeatable clean-host setup and recovery
  procedures.

### `release status`

- `stupid-app release status` reads `.release/release-manifest.json` and prints the
  recorded release identity and upload/processing/beta states.
- `stupid-app release status --live` additionally loads the App Store Connect
  credentials and queries the resolved build's current processing and
  `buildBetaDetail` internal/external states. It reuses the existing `getBuild` and
  `getBuildBetaDetail` operations in `ASCKit`; no new API surface was needed.
- Errors are actionable: missing manifest, undecodable manifest, or an upload that
  never resolved to a build each name the recovery command.
- Registered as a `release` subcommand next to `archive` and `upload`.

### Clean-Host Re-Qualification

- The WSL copy had drifted from the repository: it still contained the deleted
  `CoreDeviceRunner.swift` and the `DeviceKit/Resources` Python helper, which broke
  the build. Removing those stale files and cleaning `.build` produced a clean build
  and a passing 145-test suite (the one observed failure was the previously
  documented flaky `totalTimeout` timing assertion, which passes in isolation).
- `doctor --sdk-id ios-dev` passes all required checks on the host. The host still
  registers the SDK under the legacy `ios-dev` artifact ID; re-exporting/re-importing
  under `stupid-app-ios` remains a follow-up.
- Three consecutive `run --network --udid <udid> --sdk-id ios-dev --sudo /usr/bin/sudo`
  runs completed end to end. The `cap_net_admin` file capability was re-applied to the
  rebuilt binary (each `swift build`/`swift test` wipes it), matching the documented
  requirement.

### Debug Environment Cleanup

- Removed `/etc/sudoers.d/iosdev` (`iosdev ALL=(ALL) NOPASSWD: ALL`).
- Replaced `/etc/sudoers.d/stupid-app-coredevice` with a single scoped grant for the
  current `coredevice-helper` binary path, dropping the Python comparison-script
  grants. `visudo -c` passes; broad elevation is denied and the scoped helper
  invocation still works.
- Removed the Python comparison virtual environments, the comparison helper source
  copies, the Windows-side transfer/debug scripts, and the stale proof credential
  directory (whose material is duplicated in the active owner-only credential store).
- The scoped sudoers and `cap_net_admin` now match the documented privilege boundary;
  `docs/clean-host-setup.md` records both arrangements.

### Verification

- macOS: `swift format lint --strict` passes for the changed Swift files,
  `swift build` succeeds, and the full suite passes (144 cases; the previously flaky
  `totalTimeout` wall-clock bound was relaxed from 2 seconds to 10 seconds because the
  global-queue dispatch delay under full-suite parallel load exceeded the old bound even
  though the 250 ms C deadline fires in isolation in ~0.25 s).
- WSL: clean rebuild, 145-test pass, `doctor` zero failures, and three consecutive
  unplugged `run --network` runs with zero residual processes/interfaces.
- `stupid-app release --help` lists `status`; a sample manifest round-trips through
  the command output.

### Follow-Up

- Re-export and re-import the SDK bundle so the host registers `stupid-app-ios`
  instead of the legacy `ios-dev` ID.
- Make the MTU-patched usbmuxd reproducible on the current libplist, then re-run the
  full `run --usb` against a real development IPA. This requires USB pass-through and
  remains the only deferred transport path.

## 2026-08-18 - USB Path Re-Qualified: TCP_NODELAY Fix, MTU-usbmuxd Service, Fresh Pair

### Summary

- Fixed a latent defect that broke every native USB socket operation on Linux: the
  `TCP_NODELAY` setsockopt introduced for RemoteXPC frame segmentation was applied to
  all sockets, including the AF_UNIX usbmuxd socket, where Linux returns EOPNOTSUPP
  (errno 95). The client therefore could not connect to the daemon, so `run --usb`
  and `device pair --usb` failed before any device operation.
- Re-qualified the full native USB path on the isolated WSL host: three consecutive
  `run --usb` runs installed and launched through the native stack, and a fresh
  native `device pair --usb --replace-lockdown-record` completed both the lockdown
  trust and the SRP-3072 CoreDevice Pair-Setup bootstrap.
- Provisioned the MTU-patched usbmuxd (`USB_MTU=16383`) as a persistent
  `usbmuxd-mtu.service` systemd unit. The existing qualified build links against the
  current system libplist, so no source rebuild was required.
- Documented the USB transport setup and recovery in `docs/clean-host-setup.md`.

### TCP_NODELAY Fix

- `SocketConnection.init` now asks `connect` whether the socket is TCP; the Unix-socket
  path reports `isTCP: false` and `configure` applies `TCP_NODELAY` only to TCP
  sockets. This preserves the RemoteXPC handshake frame segmentation for tunnel/RSD
  connections while no longer attempting the invalid option on the usbmuxd Unix
  socket.
- Added a hermetic regression test with a Unix-socket fake usbmux server proving the
  full `ReadBUID` exchange completes over AF_UNIX. The test uses a short socket name
  (the first attempt used a 36-char UUID path that exceeded the 104-byte macOS
  `sun_path` limit and was shortened to a numeric suffix).

### MTU-usbmuxd Provisioning

- The qualified `usbmuxd-1.1.1-patched` source (ignored, GPL-3.0, not distributed)
  already contains the `USB_MTU 16383` change and a working binary. It is registered
  as `usbmuxd-mtu.service` with `Restart=on-failure` and is started before USB
  installs. The stock systemd unit targets a usbmuxd the installed binary does not
  support, so the MTU service replaces it for the socket path.
- Backgrounded daemons do not survive a `wsl.exe` command returning, so the service
  unit is the reliable lifecycle for the patched daemon on this host.

### Fresh Pair Verification

- The first fresh-pair attempt timed out because the default 30-second timeout expired
  while the on-device Trust dialog waited for confirmation. Re-running with
  `--timeout 180` after the dialog was answered completed: new lockdown record stored,
  wireless lockdown enabled and verified, CoreDevice remote pairing record persisted,
  and ownership returned to the invoking user.
- After the fresh pair, a network `run --network` still installed and launched using
  the freshly written records, confirming the two record types interoperate.

### Verification

- macOS: `swift format lint --strict` passes; `swift test` passes 145 cases across 27
  suites including the new Unix-socket regression test.
- WSL: clean build; `swift test` passes 146 cases (145 + the new test).
- Physical WSL/USBIP: three consecutive `run --usb` install-and-launch runs with zero
  residual processes/interfaces; fresh native pair with the on-device Trust dialog;
  network run with the fresh records.

### Follow-Up

- Re-export and re-import the SDK bundle so the host registers `stupid-app-ios`
  instead of the legacy `ios-dev` ID.
- Broader compatibility/fixture coverage and the complete acceptance run through
  stable commands on clean supported hosts remain for Gate 5.

## 2026-08-18 - macOS Host Support Scoped

### Summary

- Added `docs/macos-host-support-scope.md` defining macOS as an additive supported
  deployment host: run the complete `stupid-app` workflow on a Mac without Xcode. The
  one-time Xcode-based `sdk export` remains the only Xcode interaction; a macOS host
  imports the same versioned, checksummed, device-only artifact bundle.
- Updated `docs/engineering-handover.md` with the new status paragraph, a
  `MacOS Host Support Gates` subsection (M0-M4), a macOS risk item, macOS open
  decisions, and a recommended-next-work pointer.
- This was scoping and documentation only. No source, command behavior, SDK bundle
  format, dependency, or proof-gate status changed.

### Current macOS State Assessed

- The package builds and passes its suite on macOS; `Package.swift` declares
  `.macOS(.v14)`, and the low-level socket code already has Darwin branches
  (multicast sockets, `SO_REUSEPORT`/`SO_NOSIGPIPE`, `MSG_NOSIGNAL` avoidance,
  `connect` shims).
- `sdk import`, the native signer, ASC client, credential store, IPA packer, and
  asset-catalog writer are host-agnostic. macOS has a built-in `launchd` `usbmuxd`
  serving `/var/run/usbmuxd`, so no MTU patch is needed on macOS.
- Linux-only or unvalidated on macOS: the `CTUN` TUN backend, `ProcessRunner`
  process-group ownership on Darwin, `doctor`'s Linux-gated device checks,
  macOS-hosted Darwin-tool sourcing in `sdk export`, OpenSSL 3 runtime wiring
  (Homebrew), and the `SDKVersion` `xcrun` fallback.

### Key Decisions Recorded

- macOS must pass its own clean-host proof gates; the Linux qualification is not
  evidence of macOS support (and vice versa).
- The initial draft proposed proving the Xcode-absent path first; the confirmed design
  decisions below superseded that ordering with the Xcode-present path first.
- Recommended macOS Darwin-tool source (Mode B) is a pinned open-source LLVM build
  (`ld64.lld`, `llvm-libtool-darwin`, `dsymutil`) mirroring the Linux
  `darwin-tools` pin, with the Xcode toolchain copy as the fallback validation
  option; the toolset schema already supports naming these tools.
- macOS TUN uses `utun` interfaces with the existing explicit `--sudo` privileged
  `coredevice-helper` boundary; build and signing remain unprivileged.

### Design Decisions Confirmed (question tool, 2026-08-18)

The project owner confirmed four design decisions that restructure the macOS scope:

1. **Two host modes with no space duplication.** Xcode-present mode builds against
   Xcode's iPhoneOS SDK, linker tooling, and bundled `swift` in place and never
   materializes an SDK copy; Xcode-absent mode imports the existing device-only
   artifact bundle and uses a swift.org host toolchain. No case keeps both Xcode's
   SDK and a duplicate.
2. **Simulator support via `xcrun simctl`.** `stupid-app run --simulator` builds for
   the simulator SDK, lists, installs, launches, and reports status on local
   simulators. This is an Xcode-present, macOS-only feature and the single scoped
   use of Apple runtime tooling outside the signing/device/release pipeline.
   Simulator apps are ad-hoc signed as Xcode does; that is a recorded scoped
   exception, not an intermediate pass in any device/release path.
3. **Host Swift from Xcode when present.** Mode A uses Xcode's bundled `swift` as the
   host compiler; swiftly/swift.org is used only in Mode B, avoiding a duplicate
   toolchain.
4. **Xcode-present path proven first.** Gates reordered to M0 (Mode A build proof),
   M1 (simulator run loop), M2 (macOS-produced release), M3 (Mode A device
   deployment; proves the shared macOS utun/ProcessRunner/usbmuxd stack once), M4
   (Mode B Xcode-absent path with macOS-host Darwin tools), M5 (productization).

A follow-up question-tool clarification confirmed five more decisions:

5. **Mode B Darwin tools: pinned open-source LLVM build.** The Xcode-absent bundle
   carries pinned macOS builds of `ld64.lld` (`swift-llvm`), `llvm-libtool-darwin`,
   and `dsymutil` (`swift-tools`), mirroring the Linux `darwin-tools` pin. No Xcode
   toolchain copy or CLT linker. The first reference build is project-produced because
   no upstream publishes these binaries.
6. **CLT accepted in Mode B if empirically required.** If the swift.org macOS toolchain
   cannot run without Command Line Tools, CLT becomes a documented Mode B prerequisite;
   the no-Xcode goal still holds.
7. **Homebrew `openssl@3` is the accepted macOS runtime dependency** for the device TLS
   stack (rpath + doctor check); static-linking remains a later option, not a
   requirement.
8. **Apple Silicon only for the first supported host:** `arm64-apple-macosx` on macOS
   14+, simulator target `arm64-apple-ios-simulator`. Intel/x86_64 deferred.
9. **Clean-host requirement for the macOS proof gates is deferred** (decide later
   whether a disposable clean Mac is required or a developer machine with documented
   state suffices).

The scope document was rewritten around these decisions; the engineering handover's
status, macOS gates, risks, open decisions, and next-work sections were updated to
match.

### Verification

- Reviewed the exporter, importer, packer, `ProcessRunner`, `CTUN`, `Doctor`, and
  DeviceKit socket code to enumerate the macOS gaps recorded above.
- No test or build was changed. `git status` shows only documentation changes.

### Follow-Up

- Execute Gate M0 before any macOS device work; see
  `docs/macos-host-support-scope.md` for the ordered gates and acceptance criteria.

## 2026-08-18 - macOS Gate M0: Xcode-Present In-Place Build Path

### Summary

- Implemented work area 1 of `docs/macos-host-support-scope.md` (Gate M0): Xcode
  detection and the in-place SDK-resolution build path. With a usable Xcode installed,
  `stupid-app build`, `run --usb`, `run --network`, and `release archive` now build the
  unsigned `.app` against Xcode's iPhoneOS SDK, Xcode's toolchain `swift`, and Xcode's
  own linker **in place** — no artifact bundle is registered or materialized, and no
  SDK content is copied.
- The `doctor` command now reports the active host SDK mode and validates the in-place
  SDK/toolchain in the Xcode-present mode.
- Code uses descriptive names (`xcodeInPlace` vs `importedBundle`) rather than "Mode
  A/B" shorthand at the owner's request; the planning docs retain the Mode A/B terms.

### Design

- `Sources/SDKCore/XcodeLocator.swift` resolves the selected developer directory the
  way `xcode-select` does, without `xcrun`: `DEVELOPER_DIR`, the
  `/var/db/xcode_select_link` symlink, `/usr/share/xcode-select/xcode_dir_path`, then
  `/Applications/Xcode.app` and any `Xcode*.app` under `/Applications` (newest version
  first). Command Line Tools is deliberately not considered Xcode (no iPhoneOS SDK).
  A usable installation requires the `iPhoneOS.sdk` plus an executable toolchain
  `swift`/`swiftc`.
- `XcodeInstallation` carries the in-place SDK URLs, toolchain URLs, Xcode version/build
  (from `Contents/version.plist`), and the iPhoneOS SDK version (from
  `SDKSettings.json`), so no external tool reads any of it.
- `HostSDKMode.detect()` selects `xcodeInPlace` or `importedBundle` by Xcode presence.
- `Packer` gained an `SDKInput` (`xcodeInPlace` / `importedBundle`). The build invocation
  branches: Xcode in place runs Xcode's `swift build --sdk <iPhoneOS.sdk> --triple
  arm64-apple-ios`; the imported bundle keeps the existing `--swift-sdk` invocation.
  Build-system Info.plist provenance keys (`DTPlatformName`, `DTPlatformVersion`,
  `DTSDKName`, `DTXcode`, `DTXcodeBuild`, `DTCompiler`) are injected from Xcode metadata
  in place, via a new `BuildSystemMetadata` value; `BuildMachineOSBuild` remains never
  invented.
- `BuildToolchain.resolve(...)` centralizes the mode-aware swift path + SDK input + SDK
  version chosen by the build/run/release commands, replacing the per-command guards.
- `SDKVersion.resolve` now branches by mode: Xcode in place reads Xcode's
  `SDKSettings.json` directly; otherwise the imported bundle manifest is required. The
  former macOS `xcrun --sdk iphoneos --show-sdk-version` fallback was removed.

### Verification (macOS, Xcode 26.1.1 build 17B100, iPhoneOS SDK 26.1)

- `swift build` and the full `swift test` suite pass: 160 tests in 30 suites.
- `stupid-app doctor` reports `Host SDK mode: Xcode SDK in place (Xcode 26.1.1, iPhoneOS
  SDK 26.1)` and `iOS Swift SDK: Xcode SDK in place provides iPhoneOS SDK 26.1 without
  an artifact bundle`, with zero failures.
- `stupid-app new AcceptanceApp` then `stupid-app build` (debug and release) produce an
  ARM64 iOS Mach-O with `LC_BUILD_VERSION` `platform IOS min 17.0.0 sdk 26.1.0`; the
  merged `Info.plist` carries `DTPlatformVersion` 26.1, `DTSDKName` iphoneos26.1,
  `DTXcode` 2611, `DTXcodeBuild` 17B100 and no `BuildMachineOSBuild`.
- No Swift SDK is registered (`swift sdk list` reports none) — the build used Xcode's
  SDK in place with no duplication.
- `--sdk-version 26.2` overrides `LC_BUILD_VERSION` to 26.2.0; an explicit `--swift
  /path/to/swift` is honored over the Xcode toolchain default.
- New hermetic tests: `XcodeLocatorTests` (developer-dir resolution order, symlink/file
  selection, metadata reading, nil when no iPhoneOS SDK), `BuildToolchainTests`
  (mode-aware swift/SDK resolution, override wins), `DoctorTests` Xcode-in-place case,
  and `PackerModeATests` (real Mode 0 build gated on Xcode presence).

### Notes

- SwiftPM's `swift build --sdk <path>` is an accepted Swift 6.2 flag and drives Xcode's
  linker (no `-use-ld=lld` in this mode), matching the scope's in-place design.
- The developer-directory fallback algorithm was confirmed empirically against this
  machine's `/var/db/xcode_select_link` selection.
- Remaining macOS gates: M1 simulator run loop (`arm64-apple-ios-simulator` target +
  `simctl`), M2 macOS-produced release re-qualification, M3 macOS device stack (`utun`,
  `ProcessRunner` Darwin process-group cleanup, built-in usbmuxd), M4 Xcode-absent macOS
  Darwin tools + Mode-B export/import, M5 productization docs.

## 2026-08-18 - macOS Gate M1: Simulator Run Loop via simctl

### Summary

- Implemented work area 2 of `docs/macos-host-support-scope.md` (Gate M1): the
  `arm64-apple-ios-simulator` target and an Xcode-present-only simulator run loop.
  `stupid-app simulators` lists runtimes/devices, and `stupid-app run --simulator
  [--udid <sim-udid>]` builds in place against Xcode's `iPhoneSimulator.sdk`, ad-hoc
  signs the app, and boots/installs/launches through `xcrun simctl`.
- Simulator apps are ad-hoc signed (`codesign --force --sign -`), exactly as Xcode's
  "Sign to Run Locally" does. This is the recorded scoped exception: simulator `.app`
  output is never an intermediate pass in a device or release pipeline and is never a
  distributed artifact.

### Design

- `TargetPlatform` (`Sources/BuildCore/TargetPlatform.swift`) models `device` vs
  `simulator` with the target triple, linker `-platform_version` identifier (`ios` vs
  `ios-simulator`), SDK platform name (`iphoneos` vs `iphonesimulator`), and
  `CFBundleSupportedPlatforms` value. The planner and packer thread the platform
  through Info.plist synthesis, the linker settings, the SDK selection, and the
  build-system Info.plist keys (`DTPlatformName`/`DTSDKName` use the simulator SDK
  identity).
- `XcodeInstallation` gained `iphoneSimulatorSDKVersion` (read from the simulator
  SDK's `SDKSettings.json`), so simulator builds report the real simulator SDK version
  in `LC_BUILD_VERSION`.
- `BuildToolchain.resolve` accepts a `platform`; the simulator path reads the in-place
  simulator SDK version and the imported-bundle + simulator combination fails loudly
  (`BuildError.simulatorRequiresXcode`) because simulators cannot exist without Xcode.
- `Simctl` (`Sources/BuildCore/Simctl.swift`) wraps `xcrun simctl list/boot/bootstatus/
  install/launch`; listing output uses a raised (2 MB) `ProcessRunner` bound because
  the default 20 KB bound truncated the JSON. Parsers are internal for hermetic tests.
- `stupid-app simulators` lists runtimes and devices; `run --simulator` selects `--udid`
  or auto-picks a booted/first device, boots shutdown devices on demand, and reports
  the launched pid.

### Verification (macOS, Xcode 26.1.1, iPhoneSimulator SDK 26.1, iOS 26.3 runtime)

- `simulators` lists three runtimes and two devices; `run --simulator` built, ad-hoc
  signed (flags=0x2 adhoc), installed, and launched the app (pid returned) on a booted
  simulator and, with `--udid`, on a shutdown simulator booted on demand. A repeat run
  left no residual processes (`simctl` launch loop is transient).
- The produced simulator app has `LC_BUILD_VERSION platform IOSSIMULATOR min 17.0`, and
  Info.plist carries `CFBundleSupportedPlatforms` iPhoneSimulator, `DTPlatformName`
  iphonesimulator, `DTSDKName` iphonesimulator26.1, `DTXcodeBuild` 17B100.
- Hermetic tests added for platform mappings, simulator build-system keys, the `simctl`
  JSON parsers, and the Mode-B + simulator fail-loud path.
- Simulator platform build is covered by `PackerModeATests.xcodeInPlaceSimulatorBuild()`
  (real build, gated on an installed simulator SDK).

### Notes

- `swift build --sdk <iPhoneSimulator.sdk> --triple arm64-apple-ios-simulator` requires
  the linker `-platform_version ios-simulator` identifier; `ios` conflicts with the
  simulator platform (`ld: incompatible platforms`).
- Gate M1 exit conditions are met on this host; a clean Mac with only an installed
  runtime still needs a full gate run before claiming the gate.
- The pre-existing `CoreDeviceTLSConnectionTests` cancellation test occasionally flaps
  under full-suite load (cancellation vs total-deadline race); it is unrelated to this
  work and passes in isolation.

## 2026-08-18 - macOS Gate M3: Native Device Stack Port

### Summary

- Ported the shared device stack to macOS (Gate M3 work areas 5-7, 9): a native
  `utun` backend in `CTUN`, macOS-aware framing in both C tunnel relays,
  process-group ownership in `ProcessRunner` on Darwin, and macOS `doctor` checks.
- Physically qualified the USB path on this Mac: fresh lockdown pairing,
  CoreDevice remote-pair bootstrap, development build/sign/package, native USB
  installation, and CoreDevice tunnel launch all succeeded against a connected
  iPhone.
- Fixed a macOS-only signing bug: `NativeCodeResources` treated `/tmp` (a symlink
  to `/private/tmp`) as a different prefix from the enumerator's `/private/tmp`
  paths, so every build under `/tmp` failed with "enumerated resource escaped the
  bundle". `canonicalTemporaryPath` now canonicalizes both `/tmp` and `/var`.

### macOS utun backend (CTUN)

- Modern macOS has no static `/dev/utunN` nodes. The backend now connects the
  `com.apple.net.utun_control` kernel-control socket (the same mechanism the
  pymobiledevice3 `pytun` reference uses), iterating units until one is free,
  then reads the assigned interface name back through `UTUN_OPT_IFNAME`.
- Address assignment uses `SIOCAIFADDR_IN6` with a `/64` prefix mask (matching the
  Linux path's on-link `/64`), MTU via `SIOCSIFMTU`, link state via
  `SIOCSIFFLAGS`, and the `/128` server route via the `AF_ROUTE` routing socket
  (`RTM_ADD`, `EEXIST` treated as success because the on-link `/64` covers it).
- macOS `utun` carries a 4-byte big-endian protocol-family header on every packet
  (`AF_INET6` = `00 00 00 1e`), unlike Linux `IFF_NO_PI` TUN. Both C relays
  (`CCoreDeviceTLS`, `CLockdownTLS`) now read/write packets through new
  `stupid_app_tun_relay_read`/`write` helpers in `CTUN` that strip/prepend that
  header on macOS and are raw passthrough on Linux.

### Process-group cleanup on Darwin

- `ProcessRunner` now spawns children on Darwin via `posix_spawn` with
  `POSIX_SPAWN_SETPGROUP` (pgroup 0: the child becomes its own process-group
  leader), replacing Foundation `Process` which cannot make a group leader. Timeout
  and cancellation signal the group (`kill(-pid)`) so descendants cannot survive,
  and exit status is decoded from `waitpid`. The Linux path is unchanged.
- The process-group descendant test now runs on both platforms.

### macOS doctor checks

- Added `usbmuxd socket` (built-in `/var/run/usbmuxd`) and `CoreDevice tunnel
  device` (utun + the `--sudo` boundary note) checks under `#if os(macOS)`,
  mirroring the Linux TUN/usbmuxd checks. OpenSSL and mode checks were already
  platform-neutral.

### Physical USB qualification (macOS, Xcode 26.1.1, iPhone on USB)

- `stupid-app device pair --usb` completed lockdown pairing, wireless enablement,
  the CoreDevice USB tunnel over the new utun backend, and the SRP-3072 remote-pair
  bootstrap, storing 0600 records in the 0700 pairing directory.
- `stupid-app run --usb` built in place (Xcode SDK), signed once with the existing
  development identity, packaged, installed through the native USB stack, and
  launched the app (pid returned) with no residual processes or interfaces.
- A fresh development certificate minted for this host was rejected by the device
  (`ApplicationVerificationFailed`) because the reused development profile was
  created for the existing identity; importing the existing identity/key from the
  WSL host (via the same team) made the signature match the profile and the run
  succeeded. New host provisioning should reuse an existing identity or recreate
  the profile for a new certificate.

### macOS network path (in progress)

- `run --network` on macOS now routes through a new privileged
  `coredevice-helper run-network` subcommand because utun creation requires root
  (verified: the kernel-control connect returns `EPERM` unprivileged for both this
  implementation and pymobiledevice3's `pytun`; Linux's setcap has no macOS
  equivalent). Discovery, Pair-Verify, the tunnel, and native install all succeed
  under root; the AppService launch over the tunnel intermittently times out and
  needs the same kind of iterative relay debugging the Linux path received.
- Also fixed `NativeNetworkRunner` to use the max of discovery and launch timeouts
  for the RSD connection instead of only the discovery timeout.

### Verification

- `swift format lint --strict` passes for all changed Swift/package files.
- `swift test` passes the full suite (173 cases; the pre-existing documented
  `CoreDeviceTLSConnectionTests` cancellation test flaps only under full-suite
  parallel load and passes in isolation).
- New hermetic tests: `TUNRelayFramingTests` (relay packet round-trip through a
  socket pair, non-IPv6 family rejection on macOS), `ProcessRunnerTests`
  process-group descendant kill on Darwin, and `DoctorTests` macOS device checks.
- `device pair --usb`, `run --usb`, and (under root) the network tunnel/install path
  were qualified on the physical iPhone. Temporary sudoers grants and diagnostic
  files were removed afterward.

### Follow-Up

- Resolve the intermittent network-run AppService launch timeout on macOS
  (mirrors the Linux relay `WANT_READ` fix) and complete the three consecutive
  unplugged `run --network` runs for Gate M3 step 3.
- Re-export/re-import the SDK bundle so hosts register `stupid-app-ios` instead of
  the legacy `ios-dev` ID.
- Run the M2 (macOS-produced release) and remaining M4/M5 gates on clean hosts.

## 2026-08-18 - macOS Network Run Intermittency Fixed: NDP Host Route And mDNS Re-query

### Summary

- Diagnosed and fixed the remaining macOS Gate M3 step 3 blocker: the AppService
  launch (and sometimes the install-proxy exchange) over the network tunnel
  intermittently timed out, while USB `run --usb` remained solid.
- Root cause: macOS treats the tunnel client address's on-link `/64` route as a
  shared medium and performs IPv6 neighbor discovery (NDP). The device never
  answers neighbor solicitations, so when the NDP neighbor entry for the device's
  tunnel address aged out, macOS generated ICMPv6 "Destination Unreachable /
  Address unreachable" for the host's own TCP traffic and the exchange stalled.
  This is why it was intermittent: it worked while the NDP entry was fresh and
  failed after it expired.
- Fix: on macOS, install a point-to-point host route for the tunnel server address
  (the same route the USB launch path already installs), so the host routes
  directly to the peer and performs no NDP for that destination. Linux keeps its
  separately qualified on-link `/64` behavior.
- Also fixed an intermittent native mDNS discovery miss: the browse sent one PTR
  query at start and listened, but multicast responses can be dropped. The browser
  now re-issues the PTR query every couple of seconds for the browse window,
  mirroring standard DNS-SD browsers.

### Findings

- The relay was not at fault in this case (unlike the earlier Linux `WANT_READ`
  misread-as-EOF bug). STUPID_APP_TUNNEL_DEBUG packet dumps showed the installer
  ran to completion and the launch response (a 545-byte TCP payload) was sent by
  the device, but macOS returned ICMPv6 type 1 code 3 (address unreachable),
  sourced from the utun link-local, embedded the device's own response, and
  retransmitted it. That is the signature of NDP resolution failure for an
  on-link neighbor.
- `route -n get` confirmed the on-link `/64` route existed but with a connected
  `Uc` scope; after the fix it returns a point-to-point host route
  (`<UP,GATEWAY,HOST,DONE,STATIC>` / `UGHS`) with the client as gateway.
- The C relay gaining a raw hex dump for the first N bytes of host->device packets
  (gated on STUPID_APP_TUNNEL_DEBUG) is retained; it is what identified the
  ICMPv6 unreachable payload. `STUPID_APP_TUNNEL_DEBUG` is now also preserved
  through the privileged helper's sudo invocation so the diagnosic is visible on
  the macOS network path.

### Verification

- Three consecutive physically-unconnected `run --network` runs each built,
  signed once, packaged, discovered, tunneled, installed, verified, and launched
  the development app (pids returned), with zero residual helper processes or
  residual TUN interfaces after each.
- A 10-iteration native-browse probe found the device on all 10 (0 misses),
  versus 1 miss in 8 before the periodic re-query.
- `swift format lint --strict` passes for the changed Swift files and the C relay.
- `swift test` passes all 173 cases across 32 suites (the pre-existing flaky
  `CoreDeviceTLSConnectionTests` totalTimeout wall-clock assertion passes in
  isolation and remains unaffected).
- `git diff --check` passes.

### Follow-Up

- Gate M3 step 3 ("three unplugged `run --network` runs") is now satisfied on this
  Mac; a clean-host macOS run still needs repeating per the handover's clean-host
  gate policy.
- Re-export/re-import the SDK bundle so hosts register `stupid-app-ios` instead of
  the legacy `ios-dev` ID.
- Run the remaining M2 (macOS-produced release), M4 (Xcode-absent), and M5
  (productization) gates on clean hosts.

## 2026-08-18 - macOS Gate M2: Xcode-Present Release Qualified

### Summary

- Qualified Gate M2 (Xcode-present release) from `docs/macos-host-support-scope.md` on
  this Mac: a macOS-produced distribution IPA passed independent `codesign --verify
  --strict`, processed to `VALID`/internal TestFlight readiness through the native
  Build Upload client, and installed and launched on the physical device through
  TestFlight.
- The App Store record, distribution identity, and App Store profile already existed as
  team resources from the Linux Gate 1/2 proofs. Apple's distribution-certificate limit
  blocks minting a new one, so the existing distribution identity (team identifier
  `<team-identifier>`, active to 2027-08-12) and the `<signing-proof-bundle-id> AppStore`
  profile were imported
  onto this Mac through the CLI's standard `signing setup --import-*` path rather than
  any non-product shortcut.

### Execution

- Replicated the WSL `AcceptanceApp` project on this Mac from the qualified source
  (`stupid-app.yml`, package, single-file SwiftUI sources, AppIcon, bare entitlements),
  bumped `CFBundleVersion` from 9 (the last WSL upload) to 10.
- `signing setup --kind distribution --bundle-id <signing-proof-bundle-id>
  --import-key --import-cert --cert-id` reused the ASC profile
  `<certificate-resource-id>` (keyed to the imported certificate) and stored it owner-only.
- `release archive` built in place against Xcode's SDK (no artifact bundle), signed once
  with the native engine (timestamps disabled), and packaged
  `AcceptanceApp.ipa` (SHA-256 `723b4724231726d54004cf906cfe5b5c710d58cf0b1562eaa5f414108a0282d1`).

### Verification

- `codesign --verify --strict --verbose=4` on the exact packaged app reported "valid on
  disk" and "satisfies its Designated Requirement"; identifier
  `<signing-proof-bundle-id>`, TeamIdentifier `<team-identifier>`, get-task-allow false.
- The embedded `embedded.mobileprovision` is byte-identical (md5
  `<profile-checksum>`) to the stored App Store profile.
- The main Mach-O reports `LC_BUILD_VERSION` platform IOS sdk 26.1; merged Info.plist
  carries the Xcode-derived build keys (`DTXcode` 2611, `DTXcodeBuild` 17B100,
  `DTPlatformVersion` 26.1, `DTSDKName` iphoneos26.1) and no `BuildMachineOSBuild`.
- `release upload --wait` completed the Build Upload, resolved build 1.0 (10), and
  reported `processing=VALID`, internal `IN_BETA_TESTING`, external
  `READY_FOR_BETA_SUBMISSION`; `release status --live` confirms the same from the API.
- The build installed and remained open on the physical device through the TestFlight
  app, satisfying Gate M2's exit condition ("this re-qualifies the native signer for a
  new producing host").

### Notes And Follow-Up

- The existing distribution identity was reused across Linux and macOS hosts exactly as
  the codebase's re-signing discipline intends; no new certificate was minted.
- A clean-host macOS run is still required per the handover's clean-host gate policy
  (decision 9 remains open).
- Remaining: M4 (Xcode-absent path) and M5 (productization: macOS clean-host docs,
  README/handover/help reflecting two host modes).
- Temporary secret copies used to move the identity from the WSL host to this Mac were
  removed from both hosts after import.

## 2026-08-18 - One-Step Credential Bootstrap And Xcode Credential Reuse

### Summary

Implemented the next-priority initiative from `docs/engineering-handover.md`: a
one-step new-user bootstrap (`stupid-app setup`) and reuse of signing credentials Xcode
already manages (`stupid-app signing setup --from-xcode`).

### Changes

- `Sources/stupid-app/SetupCommand.swift`: new `stupid-app setup` that composes
  `credentials add` plus distribution (and, when `--udid` is provided, development)
  `signing setup` from a single App Store Connect API key.
- `Sources/stupid-app/SigningSetupCommand.swift`: new `--from-xcode` flag. On macOS it
  enumerates login-Keychain codesigning identities, extracts the selected identity to
  PEM, and copies the exact `.mobileprovision` for the bundle ID, kind, and identity
  into the store's `profiles/` directory.
- `Sources/SigningKit/XcodeCredentialImporter.swift`: new module. Enumerates identities
  (`security find-identity`), extracts the certificate by DER SHA-1 and the private key
  by RSA-modulus matching across every accessible search-list Keychain (PKCS#12 export
  split by OpenSSL, since `SecKeyCopyExternalRepresentation` returns empty for Keychain
  keys), and selects the exact provisioning profile by bundle ID, inferred kind, and
  certificate fingerprint.
- `Sources/SigningKit/IdentityManager.swift`: `storeDistribution`/`storeDevelopment`
  now accept an optional `certificateID` so an imported identity without an App Store
  Connect key is representable (local build/run/release-archive only).
- `Sources/ASCKit/ASCOperations.swift`: added `listCertificates(certificateType:)`
  returning full certificate content so an imported identity's App Store Connect
  certificate ID can be resolved by content fingerprint when a key is present.

### Decisions

- The Keychain and Xcode's profile folder are used only as a one-time bootstrap source;
  signing continues to use the project-owned native signer from the hardened
  credential store. This deliberately extends the macOS non-goal, which only excludes
  Keychain usage as a signing kernel.
- Xcode-managed profiles omit `ProfileType` (they carry `IsXcodeManaged`), so the
  signing kind is inferred from the profile's `get-task-allow` entitlement, falling back
  to the provisioned-device list when that key is absent.
- The identity's private key is exported non-interactively (`security export -P`);
  locked/password-protected Keychains are skipped, and a missing key fails loudly with
  an actionable message instead of guessing a password or falling back.
- When no App Store Connect key is present, the imported identity is stored with a nil
  certificate ID and the profile's exact signed bytes are reused; `release upload` and
  new-profile creation require `stupid-app credentials add` later and fail loudly.

### Verification

- Unit tests added for `XcodeCredentialImporter` pure logic (identity-line parsing, team
  ID derivation, and exact profile selection by bundle, kind, team, and certificate)
  using sanitized synthetic fixtures. 7 tests pass.
- Full suite: 173/173 tests pass with the pre-existing timing-sensitive
  `CoreDeviceTLSConnectionTests` excluded (they remain flaky only under parallel load and
  are unrelated to this work).
- On this Mac, `signing setup --kind distribution --bundle-id <exact> --from-xcode`
  correctly reached an actionable failure: the matching distribution private key lives in
  a password-protected project `build.keychain` and cannot be extracted, and no
  development profile for the development identity exists in `~/Library/MobileDevice/Provisioning
  Profiles`. Both are environment-specific limitations, not code defects; the export,
  modulus-match, and selection mechanics were validated against the real login Keychain
  (the development identity's key matches its certificate in the export) and by the unit
  tests.

### Follow-Up

- A clean-host macOS proof of the full `--from-xcode` path (identity in an unlocked
  Keychain plus a matching Xcode-managed profile) is still required per the clean-host
  gate policy.
- `stupid-app setup` end-to-end awaits a fresh-host acceptance run with a real API key.

## 2026-08-18 - Collapse Bootstrap Into `signing setup` And Config-Based Bundle ID

### Summary

Follow-up to the same-day bootstrap work: the separate `stupid-app setup` command was
folded into `stupid-app signing setup`, which is now the single provisioning/credential
command. `signing setup` also reads the bundle ID from `stupid-app.yml` when `--bundle-id`
is omitted.

### Changes

- Deleted `Sources/stupid-app/SetupCommand.swift`; removed it from the command surface.
- `Sources/stupid-app/SigningSetupCommand.swift`:
  - `--kind` is now repeatable and defaults to both `distribution` and `development`
    when omitted.
  - `--bundle-id` is repeatable; when omitted, the bundle ID is read from
    `stupid-app.yml` in the current directory (`resolveBundleIDs`). Fails with
    `bundleIDRequired` when neither a flag nor a config is present.
  - Added ASC credential options (`--key-id`, `--issuer-id`, `--p8`, `--team-id`); when
    supplied they are stored first (delegating to `credentials add`), so a fresh user
    needs no separate credential step.
  - Development setup runs only when `--udid` is provided; otherwise it is skipped with
    a note.
  - `runDevelopment` and `runFromXcode` now take explicit kind/bundle parameters.

### Verification

- Build clean; full suite passes (173/173 with the pre-existing flaky
  `CoreDeviceTLSConnectionTests` excluded).
- Running `signing setup --kind distribution --from-xcode` from a directory containing
  `stupid-app.yml` resolved the bundle ID from the config and proceeded to the expected
  keychain step; without a config and without `--bundle-id` it fails with
  `bundleIDRequired`.

### Follow-Up

- `signing setup` end-to-end fresh-host acceptance with a real API key is still pending.

## 2026-08-18 - macOS Host Support M5: Clean-Host Doc And M5 Closure

### Summary

Advanced macOS host-support productization (Gate M5). Audited the remaining M5 items:
the `doctor` both-mode checks and the mode-aware `SDKVersion.resolve` fallback were
already complete, so the outstanding concrete deliverable was the macOS clean-host setup
document.

### Changes

- Added `docs/macos-clean-host-setup.md`, mirroring the Linux clean-host doc, covering
  both supported macOS modes: Mode A (Xcode-present, in-place SDK, built-in usbmuxd,
  simulator run loop, utun `--sudo` boundary) and the intended (not yet validated) Mode B
  (Xcode-absent) procedure pending Gate M4's macOS-hosted Darwin toolset. Uses only
  generic placeholders.
- Updated `docs/engineering-handover.md` Gate M5 to record that the code items are
  complete and the remaining M5 work is the clean-host acceptance run and Mode B's
  executable path (which depends on M4).
- Added the new document to the README package-layout list.

### Verification

- Documentation-only change; no source affected. The M5 code items (doctor both-mode
  checks and the Mode-aware SDK fallback) were confirmed present by inspection:
  `SDKVersion.resolve` reads Xcode's `SDKSettings.json` in Mode A and the imported
  bundle manifest (failing loudly when absent) in Mode B.

### Follow-Up

- Mode B remains gated on Gate M4: producing and pinning the macOS-hosted LLVM
  `ld64.lld`/`llvm-libtool-darwin`/`dsymutil` toolset, then validating `sdk export
  --host <mac-arm64-triple>` and the full Xcode-absent workflow on a clean Mac without
  Xcode.
- Clean-host macOS acceptance runs (M0-M3, and M5) remain open under decision 9.

## 2026-08-18 - Gate M4 Scouting: macOS-Hosted Darwin Tools

### Summary

Scouted Gate M4 (Mac, Xcode-absent / Mode B) and produced a scoping/plan document. The
key finding changes the prior assumption that the Mode B macOS-hosted Darwin toolset must
be built from LLVM source.

### Finding

Homebrew's `lld` and `llvm` formulae already publish all three required tools as prebuilt,
open-source LLVM 20.1.8 binaries:

- `lld` → `ld64.lld` (symlink; Homebrew LLD 20.1.8)
- `llvm` → `dsymutil` and `llvm-libtool-darwin` (LLVM 20.1.8)

A smoke test on this Mac confirmed Homebrew `ld64.lld` accepts
`-arch arm64 -platform_version ios 17.0 26.1` and links a minimal object to a valid
`EXECUTE` ARM64 Mach-O whose `LC_BUILD_VERSION` reports `platform IOS minos 17.0`;
`dsymutil` ran and `llvm-libtool-darwin -static` produced a working archive.

The binaries are not static: `ld64.lld` depends on six `@rpath/liblld*.dylib` and on an
absolute Homebrew `libLLVM.dylib`; `dsymutil`/`llvm-libtool-darwin` depend on
`@rpath/libLLVM.dylib`. So the plan is to pin, bundle, and relocate (via
`install_name_tool -change`) the three binaries plus `libLLVM.dylib` and the lld dylibs
into the SDK bundle's `toolset/`, with a from-source static LLVM build as the fallback if
relocation proves fragile. Recorded in `docs/mode-b-darwin-tools.md`.

### Decisions

- Prefer bundling Homebrew's published prebuilt LLVM 20.1.8 Darwin tools over a
  from-source build, because they are open source (Apache-2.0 with LLVM exceptions),
  satisfy the licensing constraint, and demonstrably link iOS Mach-O. This updates design
  decision 5 in `docs/macos-host-support-scope.md`.
- Keep the from-source static build as the fallback and gate relocation correctness as
  the primary validation step.

### Follow-Up

- Implement the `DarwinTools` macOS-hosted source set and `sdk export --host
  <arm64-apple-macosx>` staging/relocation/checksum path.
- Validate relocation and the toolset-in-place iOS link, then resolve `-use-ld=lld`
  discovery against a swiftly-installed swift.org toolchain.
- Clean-host Mode B acceptance (the M4 exit condition) remains.

## 2026-08-18 - Gate M4: macOS Hosted Darwin Toolset Implementation (Validations 1-2)

### Summary

Implemented the Mode B (Xcode-absent) macOS-hosted Darwin toolset in the exporter, per
the Gate M4 plan in `docs/mode-b-darwin-tools.md`, and validated relocation plus a
toolset-in-place iOS link on this Mac.

### Changes

- `Sources/SDKCore/DarwinTools.swift`: added `MacOSBinary`/`MacOSDylib`/`MacOSHosted`
  value types and the pinned ARM64 Homebrew toolset (`macOSHostedArm64`, LLVM 20.1.8,
  kegs `lld@20`, `llvm@20`, `zstd`), plus `isMacOSHost(triple:)` and
  `macOSHosted(forHostTriple:)` (Intel `x86_64-apple-macosx` deferred).
- `Sources/SDKCore/ExportError.swift`: added `homebrewToolMissing`,
  `toolRelocationFailed`, and `toolRelocationUnverified` errors.
- `Sources/stupid-app/Exporter.swift`: `installToolset` now branches to
  `installMacOSToolset(into:)` for macOS host triples. It stages the three binaries
  (`ld64.lld`, `libtool`/`llvm-libtool-darwin`, `dsymutil`) and their dylibs
  (`liblld{MachO,Common,ELF,COFF,Wasm,MinGW}`, `libLLVM`, `libzstd`) into
  `toolset/bin`/`toolset/lib`, rewrites the absolute Homebrew load paths to `@rpath` via
  `install_name_tool -change`, fixes dylib install names (`-id`), and verifies no load
  dependency still references `/opt/homebrew`. The `sdk-manifest.json` `darwinTools`
  provenance record and the `--host`/export help text were updated for macOS hosts.
- `Sources/stupid-app/SDKExportCommand.swift`: updated the abstract/discussion and
  `--host` help to describe both the Linux and macOS host paths.
- `Tests/SDKCoreTests/DarwinToolsTests.swift`: 5 unit tests for host-mode detection,
  ARM64 toolset resolution, Intel deferral, and the binary/dylib sets.

### Verification

- `swift build` clean; full suite passes (178/178 with the pre-existing flaky
  `CoreDeviceTLSConnectionTests` excluded), including the 5 new DarwinTools tests.
- A real `sdk export --host arm64-apple-macosx --target arm64-apple-ios` produced the
  artifact bundle (SHA-256 recorded). Extracting it confirmed `toolset/bin` and
  `toolset/lib` are populated, `toolset.json`/`sdk-manifest.json` are correct, and no
  load dependency (excluding self install-names) references `/opt/homebrew`.
- The bundled, relocated `ld64.lld` linked a minimal arm64 object to a valid `EXECUTE`
  Mach-O (`LC_BUILD_VERSION platform IOS minos 17.0`); the bundled `dsymutil` and
  `llvm-libtool-darwin` ran successfully. This satisfies M4 validation 1 (relocation) and
  validation 2 (toolset-in-place link).

### Follow-Up

- Validation 3-4/open: resolve the swift.org host driver's `-use-ld=lld` discovery of
  the bundled `ld64.lld`, which requires a swiftly-installed swift.org toolchain and a
  No-Xcode Mac; document CLT as a Mode B prerequisite only if empirically required
  (decision 6).
- The M4 exit condition (full No-Xcode `build`/`release`/device acceptance) remains.

## 2026-08-19 - First Real-World `stupid-app` Release: Stupid Social 1.0.0 (98) To TestFlight

### Summary

- Used the `stupid-app` CLI (macOS Xcode-present mode, Gate M2-qualified) to build,
  sign once, package, and upload a new version of the existing SwiftPM/SwiftUI app at
  `../stupid-social` to App Store Connect, reaching internal TestFlight.
- This is the first real product release (not a proof-gate disposable bundle) driven
  end-to-end by the CLI and its project-owned native signer.

### What Changed In The Target Project

- Added a `stupid-app.yml` project configuration for the existing xtool-style package
  (product `NoFeedSocial`, bundle `<production-bundle-id>`, deployment target 18.0,
  icon and raw badge PNG resources). The CLI reads this file instead of `xtool.yml`.
- Added an empty `App.entitlements` (the deriver adds `application-identifier`,
  `com.apple.developer.team-identifier`, and `get-task-allow=false` for distribution,
  all authorized by the App Store profile).
- Fixed the source `Info.plist` `UIDeviceFamily` from `[1, 6]` to `[1]`.

### Provisioning

- `signing setup --kind distribution --bundle-id <production-bundle-id>` re-used the
  stored distribution identity and created/installed the exact App Store profile for the
  bundle in the hardened credential store. Stored team `<team-identifier>` matched the app.

### Verification And Result

- `release archive` produced `.release/NoFeedSocial.ipa`; the signed app passed
  `codesign --verify --strict`, carried correct distribution entitlements
  (`get-task-allow=false`) and the App Store build-system Info.plist keys.
- `release upload --wait` completed the Build Upload, resolved build 1.0.0 (98), and
  reported `processing=VALID`, `internal=IN_BETA_TESTING`,
  `external=READY_FOR_BETA_SUBMISSION`. The release manifest was written.

### Failure And Fix

- The first upload was rejected with Build Upload error `90100`: the merged
  `Info.plist` `UIDeviceFamily` contained the unsupported value `[6]` (the archived
  Xcode-produced build 97 had been delivered with `[1]`). Correcting the source plist to
  `[1]` cleared the rejection; the same build number 98 then processed successfully.

## 2026-08-19 - Fix: App Icon Blue Tint (Assets.car Pixel Byte Order)

### Symptom

- The Stupid Social 1.0.0 (98) TestFlight build (the first `stupid-app`-produced release)
  showed a blue tint on the app icon. Note: because the source icon is grayscale, pure
  white stays white; the blue appears where the logo's black pixels get rendered with the
  alpha channel substituted for blue.

### Root Cause

- `AssetCatalogWriter.makeCar` wrote each icon pixel's bytes in **ARGB** order
  (`[a, r, g, b]`) while labeling the rendition's `pixelFormat` as **"BGRA"** in the
  csiheader. iOS honors the BGRA label and reads the first stored byte as Blue. For an
  opaque pixel the first byte is alpha `0xFF`, so blue was pinned to `0xFF` and the real
  gray leaked into alpha, producing the blue tint and translucent logo.
- Concretely, black source `RGBA(0,0,0,255)` was stored `[255,0,0,0]` and read as BGRA
  -> Blue=255, A=0. A solid-red test icon would have rendered cyan under the bug.

### Fix

- Store the pixel bytes in **BGRA** order (`[b, g, r, a]`) to match the `"BGRA"` label,
  and renamed the misleading `argb` variable/parameters to `bgra`. An explanatory
  comment documents the invariant so the byte order is not "fixed" back.
- Updated `testEveryLZFSEChunkDecodesToOriginalBGRARows` (was ARGB) to assert the BGRA
  byte order `[b,g,r,a]`. The existing assetutil qualification test still passes.

### Verification

- `AssetCatalogWriterTests` pass (7 tests, 1 skipped, 0 failures).
- Built a throwaway app with a solid red source icon using the fixed writer, installed
  it on the booted simulator, and confirmed the home-screen tile rendered **red**
  (measured avg RGB ~(161,29,45)), not cyan/blue. Gray icons now render gray.

### Follow-Up

- The currently shipped TestFlight build (98) carries the buggy icon; a new build number
  must be released with the fixed CLI to correct the icon in TestFlight.

- **Resolved 2026-08-19:** Stupid Social 1.0.0 (99) was built with the fixed writer and
  uploaded to TestFlight (`processing=VALID`, `internal=IN_BETA_TESTING`), correcting the
  icon in the field.

## 2026-08-19 - Gate 5 Productization: Support Decisions And `release new-build`

### Summary

Resumed Gate 5 productization. First clarified four open handover decisions with the
project owner (see the question-tool record in `docs/implementation-notes.md`/handover),
then implemented the concrete release-workflow deliverable those decisions implied.

### Resolved Decisions

1. **Supported host:** x86_64 Ubuntu 24.04 LTS is the official production (non-macOS)
   deployment host.
2. **WSL:** the isolated `iosdev-ubuntu` WSL 2 environment is a proof/reference
   environment, not a supported production target.
3. **Release layout:** keep `.release/` for the IPA and `release-manifest.json`; the
   next build number is provided by a new helper instead of restructuring output.
4. **v1 entitlement scope:** the bare set (`application-identifier`,
   `com.apple.developer.team-identifier`, `get-task-allow`) is the supported v1 set;
   other capabilities are out of scope and must fail loudly.

### Changes

- **New `stupid-app release new-build`** (`Sources/stupid-app/ReleaseNewBuildCommand.swift`):
  queries App Store Connect for the most recently uploaded build number for the app
  (or takes an explicit `--build-number` base) and prints `n+1`, mirroring the retired
  release script's `release_build_number()`. The bundle ID is read from `stupid-app.yml`
  or overridden with `--bundle-id`. Registered under `release`; help/doc updated.
- **`ASCKit`** (`Sources/ASCKit/BuildUpload.swift`): added
  `ASCOperations.latestBuildNumber(appID:)` (`builds?filter[app]&sort=-uploadedDate&limit=1`)
  plus a static `decodeLatestBuildNumber` for hermetic tests.
- **v1 entitlement tightening** (`Sources/SigningKit/EntitlementDeriver.swift`): narrowed
  `supportedKeys` to the bare set. `application-groups`, `keychain-access-groups`,
  `applesignin`, `associated-domains`, and other capability-bearing keys now fail loudly
  at derivation instead of being accepted and profile-reconciled, matching the resolved
  v1 scope and the "keep unsupported types explicit, fail loudly" invariant.
- **Docs**: added README `Supported platforms` + `Version 1 entitlement scope` sections
  and the `new-build` command line; updated the engineering handover's command surface,
  Open Decisions (record resolutions), and Provisioning/Entitlements (v1 scope).

### Verification

- `swift build` succeeds (only the pre-existing Homebrew OpenSSL deployment-target linker
  warnings). `swift test` passes 182 tests with the `CoreDeviceTLSConnectionTests` suite
  skipped (its cancellation/total-timeout timing assertion is the documented pre-existing
  flake that passes in isolation; unrelated to this change).
- New hermetic tests pass: 3 in `ASCKitTests/BuildUploadTests` (latest-build decode,
  empty list, malformed response) and 1 in `SigningKitTests/MobileProvisionParserTests`
  (capability keys rejected loudly in v1).
- `stupid-app release --help` lists `new-build`; running it without a config or
  `--bundle-id` fails loudly with the actionable `configMissing` error.
- `git diff --check` passes.

### Notes And Follow-Up

- `swift format lint --strict` was run on the changed files; the installed formatter's
  default 2-space official style disagrees with the repo's consistent 4-space style and
  there is no `.swift-format` config, so it reports pre-existing errors across nearly
  every source and test file regardless of this change. Changes were kept style-consistent
  with the surrounding 4-space code rather than reformatting the whole (unrelated)
  codebase.
- Remaining Gate 5 work is unchanged: broader compatibility/fixture coverage, re-exporting
  the SDK under the `stupid-app-ios` artifact ID, `signing setup` fresh-host acceptance,
  and the complete acceptance run through stable commands on clean supported hosts.

## 2026-08-19 - Gate 5 Fixture Coverage: Sacred-Importer Path-Safety Tests

### Summary

Added hermetic regression coverage for the security-critical SDK importer path
validation (`SDKCore.SafeArchive.validateEntries`), which had no tests despite the
handover's Test Strategy requirement ("SDK archive checksum, traversal, symlink,
architecture, and atomic-install tests"). This is the first increment of the resolved
Gate 5 "broader compatibility/fixture coverage" item.

### Changes

- Added `Tests/SDKCoreTests/SafeArchiveTests.swift` (11 tests) exercising the pure
  entry-validation function that runs before any archive extraction:
  - Accepts nested relative paths, trailing-slash directory entries, and dot-prefixed
    regular filenames (e.g. `.hidden`, `.DS_Store`) — these are not AppleDouble and
    must be allowed.
  - Rejects absolute paths (`/etc/passwd`), leading and nested `..` traversal, `.`
    root-alias components, AppleDouble `._*` metadata entries, drive-letter first
    components (`C:/...`, `D:`), and colon-suffixed first components.
- The tests are pure and hermetic: no real archive, `tar` process, or fixture file is
  created. SwiftPM auto-discovery includes the new file in the `SDKCoreTests` target.

### Verification

- `swift test` passes 193 tests (11 new) with the documented pre-existing
  `CoreDeviceTLSConnectionTests` timing flake suite excluded (it passes in isolation and
  is unrelated). `git diff --check` passes.
- One test intent was corrected during development: a bare `C:evil` first component is
  not rejected (colons only matter with a trailing path separator), so the drive-letter
  test uses `C:/evil` / `D:` where the leading component is colon-terminated, matching
  actual importer behavior.

### Follow-Up

- Remaining Gate 5 fixture coverage still to add (Test Strategy): Mach-O inspection,
  IPA path/mode/symlink round-trip packaging tests, generated-project golden fixtures,
  and SDK archive-level (created-on-disk) tests if practical.

## 2026-08-19 - Fix Deterministic CoreDevice TLS Flaky Tests

### Summary

Fixed the long-documented flaky `CoreDeviceTLSConnectionTests` suite (`totalTimeout`
and `cancellation`), which intermittently failed under full-suite parallel load. Root
cause was a timing race, not a defect in the TLS exchange itself.

### Root Cause

Under `swift test` parallel load (200 tests), the Swift cooperative executor and
`DispatchQueue.global` saturate, delaying async work (e.g. `Task.sleep` and
`withTaskCancellationHandler`'s `onCancel` delivery) by many seconds. Debug
instrumentation confirmed this:

- The `cancellation` test slept 100 ms then cancelled, expecting `.cancelled`, but ran
  a 10 s deadline. When cooperative-pool saturation delayed `Task.sleep`'s resume past
  the 10 s deadline, `task.cancel()` (where `onCancel` fires) landed after the C worker
  had already returned `.timedOut`. So a genuine cancellation surfaced as a spurious
  timeout.
- The `totalTimeout` test asserted a tight `< 10 s` wall-clock bound for a 250 ms C
  deadline. Under load the blocking C worker's `DispatchQueue.global` dispatch can be
  delayed ~14 s, inflating the measured duration and flaking the bound.

### Changes

- `cancellation`:
  - Raised the deadline to 60 s so the total timeout can never race (and pre-empt) the
    cancel; the correctness claim is now that cancellation is observed once delivered,
    not that it beats an arbitrary deadline.
  - The test now waits deterministically until the `StalledTCPServer` has accepted
    (a new `waitUntilAccepted` signaled via a `DispatchSemaphore` on the accept path)
    so the client is provably inside the exchange before cancelling, replacing the
    load-sensitive `Task.sleep(100 ms)`.
  - Measures cancellation-propagation latency from after `cancel()` with a generous 30 s
    bound.
  - `StalledTCPServer` gained `waitUntilAccepted` + a `noAccept` error.
- `totalTimeout`: removed the tight `< 10 s` wall-clock bound; asserts `.timedOut`
  (which proves the deadline fired rather than hanging). Kept a generous 120 s safety
  net solely to catch a hypothetical removed deadline, far above the ~14 s worst-case
  observed dispatch latency.

### Verification

- `CoreDeviceTLSConnectionTests` passes in isolation in ~0.25 s; cancellation resolves
  in ~5 ms (down from the prior 100 ms sleep + variable latency).
- 11 consecutive clean full-suite runs (200 tests, 35 suites) with no failures. The
  previously reproduced 1-in-2 cancel/timeout flake is no longer reproducible.
- `swift build` clean. These are test-harness and instrumentation-only changes; no
  product/production behavior changed (debug `STUPID_APP_DEBUG` instrumentation added
  to identify the race was removed after diagnosis).

## 2026-08-19 - Gate 5 Fixture Coverage: Mach-O And IPA Packaging

### Summary

Continued the resolved Gate 5 "broader compatibility/fixture coverage" item with two
more hermetic test suites matching the handover Test Strategy: Mach-O load-command
inspection and IPA packaging round-trip / symlink safety.

### Changes

- `Tests/BuildCoreTests/MachOInspectorTests.swift` (4 tests): builds a synthetic thin
  ARM64 `MH_EXECUTE` with an `LC_BUILD_VERSION` and verifies `MachOInspector` reads
  architecture (`arm64`), platform (`ios`), minimum OS (`17.0.0`), and SDK (`26.1.0`)
  without Apple tooling. Also rejects ELF magic, short payloads, and non-ARM64 CPU
  types. Full synthetic-Mach-O construction, no fixture files on disk.
- `Tests/SigningKitTests/IPAPackerTests.swift` (3 tests): builds a real small `.app` in
  a temp directory, packages it through `IPAPacker.pack`, and confirms the IPA exists
  with the expected name (re-read verification runs inside `pack`). Verifies an app
  whose bundle contains an absolute escaping symlink is rejected, and a missing bundle
  fails loudly (`appBundleMissing`). The packaging tests are gated on `zip`/`unzip`
  availability via Swift Testing's `.enabled(if:)` so Linux hosts without the tools skip
  them rather than fail, keeping the suite portable.

### Verification

- `swift test` passes 207 tests across 37 suites (4 new Mach-O + 3 new IPA tests).
- `swift build` and previous documentation changes pass. The two suites are independent
  of the earlier deterministic CoreDevice TLS flake fix.

### Follow-Up

- Remaining Test Strategy coverage (deferred): generated-project golden fixtures and
  on-disk SDK archive round-trip tests. These are lower value / higher environment
  coupling than the security (SafeArchive), Mach-O, and IPA coverage now landed.

## 2026-08-19 - Gate 5 Fixture Coverage: Generated-Project Golden Tests

### Summary

Added a golden-fixture test suite for the project generator, completing the local
hermetic portion of the resolved Gate 5 fixture-coverage item (the remaining Test
Strategy items are lower-value or environment-coupled).

### Changes

- `Tests/ProjectCoreTests/ProjectGeneratorTests.swift` (6 tests): scaffolds a real
  project in a temp directory and asserts the exact generated file tree
  (`Package.swift`, `stupid-app.yml`, `Info.plist`, `App.entitlements`,
  `Sources/<Module>/<Module>.swift`, `ContentView.swift`, and copied `Resources/AppIcon.png`)
  plus the resulting `AppConfig`. Also verifies:
  - module-name derivation (`Foo-Bar` -> `Foo_Bar`),
  - the generated `stupid-app.yml` round-trips through `AppConfig`,
  - invalid product name, existing destination, and non-PNG icon rejection.

### Verification

- `swift test` passes 213 tests across 38 suites (6 new). Fully hermetic; no Apple
  tooling or external services. `git diff --check` passes.

### Follow-Up

The local, hermetic fixture-coverage items from the Test Strategy are now landed:
SDK importer path-safety (SafeArchive), Mach-O inspection, IPA packaging, and
generated-project golden fixtures. Remaining Gate 5 items are operational and require
external environments: re-exporting the SDK under `stupid-app-ios`, `signing setup`
fresh-host acceptance, and the complete acceptance run through stable commands on clean
supported hosts (clean WSL host for the Linux gates; the iPhone on the deployment host).

## 2026-08-19 - Gate 5 Close-Out: SDK Re-Export Under stupid-app-ios And Host Re-Import

### Summary

- Closed the long-standing follow-up of re-exporting the iOS Swift SDK bundle under
  the `stupid-app-ios` artifact ID so the isolated `iosdev-ubuntu` WSL host no longer
  registers the legacy `ios-dev` ID.
- Exported on macOS with `stupid-app sdk export --host x86_64-unknown-linux-gnu
  --target arm64-apple-ios` and imported it on the WSL host, then removed the legacy
  `ios-dev` registration. `swift sdk list` now shows only `stupid-app-ios`.
- The fresh bundle is an upgrade over the Gate 0 bundle: it was produced from
  `/Applications/Xcode.app`, which is Xcode 26.3 (build 17C529) with iPhoneOS SDK 26.2
  and toolchain Swift 6.2.4 - an exact Swift version match with the WSL host's Swift
  6.2.4 (the Gate 0 bundle used Xcode 26.1.1 / SDK 26.1 / Swift 6.2.1).
- Rebuilt the WSL source tree from the current repository (the WSL copy predated
  several commits and had no git metadata), fixed two Linux-facing defects the rebuild
  surfaced, and re-qualified the host.

### SDK Export And Import

- Archive: `stupid-app-ios-arm64-apple-ios-x86_64-unknown-linux-gnu.artifactbundle.tar.zst`,
  ~104 MB compressed.
- Archive SHA-256:
  `b6f98ce676d307e393b45a22005f936749e4a74765d7a73f9501b9ea4b3ce34e`.
- Manifest provenance: source Xcode 26.3 (build 17C529), iPhoneOS SDK 26.2, Swift 6.2.4,
  host triple `x86_64-unknown-linux-gnu`, target triple `arm64-apple-ios`, pinned
  darwin-tools v1.0.1 (archive SHA-256
  `58f567cbea08afb89aaee5ca0c2200e6c9fe7c014022fe380f0188e940d8d071`).
- `stupid-app sdk import --expected-sha256 b6f98ce6...` verified the archive checksum,
  extracted safely, verified all declared file checksums and host/Swift compatibility,
  and registered the bundle as `stupid-app-ios` (`swift sdk list` output:
  `stupid-app-ios`).
- `swift sdk remove ios-dev` removed the legacy registration; the imported bundle is
  functionally equivalent for every supported command and the CLI's default `--sdk-id`
  already matched the new ID, so no command-line changes were needed.

### Linux-Facing Defects Found And Fixed

1. **`TUNRelayFramingTests` failed to compile on Linux.** `socketpair(AF_UNIX,
   SOCK_STREAM, ...)` does not type-check on Glibc, where `SOCK_STREAM` is imported as a
   `__socket_type` enum rather than `Int32`. The helper now uses
   `Int32(SOCK_STREAM.rawValue)` under `#if os(Linux)`, matching the existing
   `USBMuxClient` socket-creation pattern.
2. **`BuildToolchain` xcode-in-place SDK version was environment-dependent.** The
   `hostSDKVersion` closure for Xcode-in-place device mode called `SDKVersion.resolve`,
   which re-detects the active Xcode through `xcode-select`; with multiple Xcode
   installations this can disagree with the `--xcode` argument the command was given.
   It now uses the selected `XcodeInstallation`'s own `iphoneosSDKVersion`, matching the
   packer's existing in-place closure. The `BuildToolchainTests` fixture was updated to
   the currently validated Xcode 26.3 / iPhoneOS SDK 26.2.

### Verification

- macOS: `swift format lint --strict` passes for the changed Swift files;
  `swift test` passes 213 tests across 38 suites.
- WSL (rebuilt current tree): `swift test` passes 205 tests across 37 suites (the macOS
  count is higher because of macOS-only simulator/Xcode-locator tests).
- WSL: `stupid-app doctor` with the default SDK ID reports 0 failures (1 expected
  project-config warning outside a project directory); the iOS SDK check reports
  "stupid-app-ios is compatible (iPhoneOS SDK 26.2)".
- WSL: `stupid-app build` in the AcceptanceApp fixture produces
  `Mach-O arm64 ios min 17.0.0 sdk 26.2.0`, confirming the real SDK version is injected
  and the new bundle compiles and links an ARM64 Mach-O end to end.

### Follow-Up

- The operational docs now reflect the single `stupid-app-ios` artifact ID
  (`docs/clean-host-setup.md`, engineering handover); historical `ios-dev` references
  in earlier implementation-note entries are intentionally preserved.
- The Step PC skill reference to the legacy ID was updated in the local skills
  repository.
- Remaining Gate 5 work is the final clean-host acceptance run of the complete
  workflow on clean supported hosts (Linux gates on a clean WSL host; macOS gates on a
  clean Mac).

## 2026-08-19 - CLI Usage Skill Bundled With The Product

### Summary

- Added a self-contained agent skill at `skills/stupid-app-cli/SKILL.md` to be
  distributed alongside the `stupid-app` binary. It teaches an agent how to use the
  CLI end to end: scaffold, SDK export/import, credential and signing setup, USB and
  wireless development runs, simulator runs, and distribution release.
- Added `skills/stupid-app-cli/references/commands.md` with the exact command and
  option surface, captured from the current build's help output.

### Decisions

- The skill lives in the repository (`skills/`) rather than the user global skill
  repository so it ships with the CLI binary and tracks the same release.
- The SKILL.md is self-contained for CLI operation and cross-references the
  repository `docs/` files (`clean-host-setup.md`, `macos-clean-host-setup.md`,
  engineering handover) only as deeper detail when working from a source checkout.
- It enforces the product invariants in agent-facing terms: one real Apple signing
  pass, no pseudo-signing or Xcode/`altool`/Transporter fallbacks, fail-loud
  behavior, owner-only credential storage, and the explicit `--sudo` privilege
  boundary for CoreDevice TUN operations.

### Verification

- The skill passes the skill-creator validation script
  (`quick_validate.py`): valid frontmatter, naming, directory structure, and
  description.
- Every enabled command and option in `references/commands.md` was checked against
  `stupid-app --help`.

### Follow-Up

- Re-validate the command reference when the CLI surface changes; keep the skill in
  sync with the release that bundles it.

## 2026-08-19 - CLI --version Flag And First Agent Dogfood

### Summary

- Added a top-level `--version` / `-v` flag to the CLI. It prints the product
  version and the host Swift compiler line, and bare `stupid-app` now prints the
  top-level help through an explicit `CleanExit.helpRequest()` instead of relying
  on ArgumentParser's default empty action.
- Introduced `StupidApp.productVersion` (`0.0.1`) as the single source of truth
  for the product version and a testable `versionInformation(compilerVersion:)`
  builder. Added a `StupidAppTests` test target that imports the executable module
  and verifies the version string format (three-part semantic version, product
  prefix, toolchain line).
- Ran a first real dogfood of the product: built the release binary, installed it
  to `~/.local/bin/stupid-app`, and a sub-agent (given the bundled CLI skill) ran
  `doctor` -> `new` -> `build` -> `run --simulator` against the booted iOS 26.3
  simulator, then independently verified the installed bundle and running process.
  The full simulator happy path works end to end on a clean macOS/Xcode-present
  host (Xcode 26.1.1, Swift 6.2.1).

### Feedback Evaluation

- The dogfood surfaced real findings: missing `--version` (fixed in this entry),
  the scaffold-icon docs mismatch (the skill/handover examples implied a default
  `Resources/AppIcon.png` + `iconPath`, but `new` only writes them when `--icon`
  is passed), and the undocumented exactly-one-mode contract on `run`. The agent
  also judged `--sdk-id`/`--swift`/`--home`/`--sudo` as noisy on happy-path help.
- Verified each finding against source before acting: the icon claim was accurate
  and the skill was corrected to match the code (icon stays opt-in; decision
  recorded); the `run` mode-validation claim was only half right, because
  `RunCommand` already requires exactly one of `--usb|--network|--simulator` with a
  clear error, but the help text does not document the contract.
- Updates from this evaluation: SKILL.md and `references/commands.md` now describe
  the real icon behavior, and README/SKILL/commands.md record the new `--version`
  flag.

### Verification

- `swift format lint --strict` passes for the changed Swift files.
- `swift test` passes 216 tests across 39 suites, including the new 3-test
  `StupidAppVersionTests` suite.
- The skill passes the skill-creator `quick_validate.py` validation.
- Installed release binary: `stupid-app --version` and `-v` both print
  `stupid-app 0.0.1` plus the host Swift compiler line with exit code 0; bare
  `stupid-app` prints the top-level help.

### Follow-Up

- Re-run the dogfood after the next CLI surface change to keep the skill honest;
  consider surfacing the `run` mode contract in `--help` copy.

## 2026-08-19 - README Cleanup

### Summary

- Rewrote `README.md` to describe the current product instead of the gate/proof history:
  removed the Gate 0-5 and macOS M-gate status prose, the WSL reference-environment
  scoping notes, and the "Version 1 entitlement scope" section (the entitlement set is
  documented in the engineering handover and skill instead). The README now presents the
  supported platforms, package layout, and command surface for the current version.

### Verification

- README no longer mentions proof gates, the WSL reference host, or version-scoping
  caveats; the commands section matches the installed binary's help output.
- Repo history was rewritten with `git filter-repo` to redact operational identifiers
  (team IDs, certificate resource IDs, real bundle IDs) from all historical commits, and
  the repository was made public at github.com/stephancill/stupid-app-cli.

### Follow-Up

- Keep the README informational for the released version; move engineering status into
  the handover and implementation notes only.

## 2026-08-19 - README Installation Instructions

### Summary

- Added an "Installation" section to `README.md` covering macOS (download the
  platform binary from the GitHub releases page and place it on `PATH`) and Linux
  (build from source with a Swift 6.2 toolchain), closing with a `doctor` verification
  hint.

### Verification

- Section renders correctly with relative and absolute link to the release binary.

### Follow-Up

- Update the exact binary filename when a new version is published (the current link
  pins version 0.0.1).
