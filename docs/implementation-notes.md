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
