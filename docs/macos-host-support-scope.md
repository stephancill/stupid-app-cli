# macOS Host Support Scope

## Purpose

This document scopes making macOS a first-class supported deployment host for
`stupid-app`, so a developer on a Mac can run the complete workflow — create, build,
sign, deploy to a physical iPhone, and release to App Store Connect — with or without
Xcode installed.

This is an additive host-support initiative. It does not change the Linux path, which
remains the validated reference host. macOS must pass its own clean-host proof gates
before any compatibility claim is made; the existing rule applies symmetrically: a Linux
qualification is not evidence of macOS support and vice versa.

Implementation status (2026-08-18, updated): the scoping proposal with design
decisions is confirmed. Gate M0 (work area 1, the Xcode-present in-place SDK build
path) and Gate M1 (work area 2, the simulator run loop) are implemented: the Xcode
locator, host-SDK-mode detection, the in-place packer path, the mode-aware SDK-version
resolution, the `doctor` host-mode check, the `arm64-apple-ios-simulator` target, and
`run --simulator`/`simulators` via `simctl` all landed and were verified on this Mac.
Gate M3 (the shared device stack) is now ported: work area 5 (utun backend in `CTUN`
via the `com.apple.net.utun_control` kernel-control socket, with macOS-aware 4-byte
protocol-family framing in both C tunnel relays), work area 6 (Darwin process-group
cleanup in `ProcessRunner` via posix_spawn), work area 7 (native USB verified against
the built-in usbmuxd), and work area 9 (macOS `doctor` checks) are implemented.
`device pair --usb` and `run --usb` are physically qualified on a Mac against a
connected iPhone. The network path now owns the utun inside a privileged
`coredevice-helper run-network` subcommand (utun creation requires root on macOS);
discovery, Pair-Verify, tunnel, and install work under root, but the AppService launch
over the tunnel intermittently times out and Gate M3 step 3 (three unplugged
`run --network` runs) remains open. The remaining gates (M2 release, M4 Xcode-absent,
M5 productization) are unchanged and still require clean-host proof.

## Design Decisions (confirmed)

The following decisions were confirmed with the project owner on 2026-08-18:

1. **Two host modes with no space duplication.** When Xcode is installed, `stupid-app`
   builds against Xcode's iPhoneOS SDK and Xcode's own linker tooling **in place** and
   never materializes a copy of the SDK. When Xcode is absent, it imports the existing
   device-only artifact bundle (`stupid-app sdk import`) and builds with the bundle's
   bundled tools. No case keeps both Xcode's SDK and a duplicate copy.
2. **Simulator support via `simctl`.** `stupid-app run --simulator` builds for the
   simulator SDK, lists available simulators, installs, launches, and reports status
   through `xcrun simctl`/CoreSimulator. Simulator runtimes and CoreSimulator only exist
   with Xcode, so this is an Xcode-present, macOS-only feature and the single scoped
   use of Apple runtime tooling outside the signing/device/release pipeline.
3. **Host Swift from Xcode when present.** In Xcode-present mode the CLI uses Xcode's
   bundled `swift` as the host compiler. A swiftly-installed swift.org toolchain is used
   only in Xcode-absent mode. This avoids a duplicate ~1-2 GB toolchain.
4. **Xcode-present path proven first.** The Xcode-present mode (build, release, then
   device) is proven before the Xcode-absent mode because it reuses the qualified signing
   and release pipeline, requires no new Darwin-tool sourcing, and unlocks simulator
   support early. The shared macOS device-stack work (TUN, process cleanup) is proven
   once in Xcode-present mode and reused by Xcode-absent mode.

A follow-up clarification on 2026-08-18 confirmed five more decisions:

5. **Mode B Darwin tools: pinned LLVM build.** The Xcode-absent bundle carries a pinned
   macOS build of `lld`'s `ld64.lld`, `llvm-libtool-darwin`, and `dsymutil`, mirroring
   the Linux `darwin-tools` pin (checksummed, auditable, Apache-2.0-with-LLVM-exceptions).
   No Xcode toolchain copy or CLT linker is used. The first reference build is produced by
   this project because no upstream publishes these binaries.
6. **Command Line Tools are acceptable in Mode B if empirically required.** If the
   swift.org macOS toolchain cannot run without CLT, CLT becomes a documented Mode B
   prerequisite. The no-Xcode goal still holds; CLT is not Xcode and is a much smaller
   dependency.
7. **OpenSSL 3 is a Homebrew runtime dependency on macOS.** `openssl@3` is accepted and
   documented; the build wires rpath and `doctor` checks it. Bundling/static-linking
   remains a later reconsideration, not a requirement.
8. **Apple Silicon only for the first supported macOS host.** The first supported matrix
   is `arm64-apple-macosx` on macOS 14+ (the `Package.swift` platform). Intel hosts and
   `x86_64-apple-macosx` Mode B bundles are deferred until an Intel host is available.
9. **Clean-host decision deferred.** Whether macOS proof gates require a disposable clean
   Mac or may run on a developer machine with documented state is decided later.

## Goal And Non-Goals

Goal: on a supported macOS host, after either detecting Xcode or importing an SDK
bundle, a user can run:

```bash
stupid-app doctor
stupid-app new AcceptanceApp
cd AcceptanceApp
stupid-app build
stupid-app run --simulator [--udid <sim-udid>]   # Xcode-present only
stupid-app credentials add
stupid-app signing setup --kind development
stupid-app device pair --usb
stupid-app run --network --udid <udid>
stupid-app release archive
stupid-app release upload --wait
```

Non-goals:

- Removing the one-time Xcode-based `sdk export` step for the Xcode-absent mode. Export
  inherently requires Xcode; it may run on any Mac, not necessarily the deployment Mac.
  In Xcode-present mode no export/import is needed at all.
- Using Xcode build tooling (`xcodebuild`, `altool`, Keychain identities, `xcrun` as a
  signing kernel) as a product dependency in Xcode-present mode. The mode uses Xcode's
  SDK contents, linker, and bundled `swift` as inputs only; provisioning, signing,
  device transport, and App Store Connect upload remain project-owned. `simctl` is the
  explicit exception for simulator execution (decision 2), and macOS-only independent
  verification tools (`codesign --verify --strict`, `assetutil`) remain acceptable for
  qualification as they are today.
- Changing the SDK bundle format, signing pipeline, or App Store Connect flow.
- Bundling the macOS SDK, simulator platforms, or any Apple SDK payload in the export.
- Simulator support without Xcode (simulators cannot exist without Xcode).
- Replacing raw-USB transport (`usbmuxd` replacement remains deferred).
- Windows or other new hosts.
- Arbitrary Xcode projects; version 1 remains CLI-owned SwiftPM/SwiftUI apps.

## Current State On macOS

The following already holds and does not need to be rebuilt:

- The package builds and its full test suite passes on macOS (`swift build`,
  `swift test`); `Package.swift` declares `.macOS(.v14)`.
- Low-level socket code has Darwin branches: mDNS multicast sockets,
  `SO_REUSEPORT`/`SO_NOSIGPIPE`, `MSG_NOSIGNAL` avoidance, `connect` shims.
- `sdk export` runs on macOS and is the only command that touches Xcode.
- `sdk import` is cross-platform and rejects a host-triple mismatch, so a macOS-host
  bundle is imported the same way as a Linux-host bundle.
- The native signer, ASC API client, credential store, IPA packer (`/usr/bin/zip`, which
  exists in the macOS base OS), and asset-catalog writer are host-agnostic.
- macOS has a built-in `usbmuxd` managed by `launchd` serving `/var/run/usbmuxd`, so the
  USB path needs no MTU patch or daemon provisioning (no USBIP layer exists on macOS).

The following was Linux-only or unvalidated and is the subject of this scope
(resolved since the last update where noted):

- The packer always builds through `swift build --swift-sdk <bundle>`. Xcode-present
  mode needs a new in-place SDK-resolution path (decision 1). **Resolved (Gate M0).**
- `CTUN` (`Sources/CTUN/TUN.c`) is `__linux__`-only; it returns `UNSUPPORTED` on macOS.
  Network and USB CoreDevice tunnels therefore cannot run on macOS. **Resolved (Gate
  M3): a macOS `utun` backend via the `com.apple.net.utun_control` kernel-control
  socket, plus macOS-aware 4-byte protocol-family framing in both C tunnel relays.
  Note: utun creation requires root on macOS (kernel-control connect returns `EPERM`
  unprivileged, matching pymobiledevice3's `pytun`), so macOS network runs route the
  TUN lifetime through the privileged `coredevice-helper run-network` subcommand.**
- `ProcessRunner` deliberately does not own a process group on Darwin
  (`ownsProcessGroup = false`), so timeout/cancellation escalation cannot currently
  signal descendant processes. **Resolved (Gate M3): Darwin launches use posix_spawn
  with `POSIX_SPAWN_SETPGROUP` so children are group leaders and `kill(-pid)` reaches
  descendants.**
- `doctor` gates the TUN device and usbmuxd socket checks behind `#if os(Linux)`;
  macOS has no equivalent checks (notably OpenSSL 3, utun, and Xcode presence).
  **Partially resolved (Gate M3): macOS `doctor` now reports the built-in usbmuxd
  socket and the utun/`--sudo` boundary.**
- The SDK exporter only provisions Linux-hosted Darwin tools
  (`darwin-tools-linux-llvm`, x86_64). A macOS-host bundle (Xcode-absent mode) needs
  macOS-hosted Darwin tools; `sdk export --host <mac-triple>` fails loudly today.
- `SDKVersion.resolve` has a macOS-only `xcrun --sdk iphoneos --show-sdk-version`
  fallback that is only valid in Xcode-present mode and must fail loudly in
  Xcode-absent mode.
- OpenSSL 3 is not part of macOS; the CLI links `libssl`/`libcrypto` at runtime and the
  tests use Homebrew `openssl@3`. No product runtime story, rpath wiring, or `doctor`
  check exists for macOS.

## Host Model: Two Modes

macOS support is defined by two mutually exclusive modes selected at `doctor`/build time
by Xcode presence. Shared with both modes: the signing pipeline, ASC upload, credential
store, and device stack once the macOS device work lands.

Supported matrix (decision 8): the first supported host is Apple Silicon macOS 14+,
host triple `arm64-apple-macosx`, with the `arm64-apple-ios-simulator` simulator target in
Mode A. Intel (`x86_64-apple-macosx`) hosts and their Mode B bundles are deferred.

### Mode A: Xcode-present

Active when an Xcode installation with an iPhoneOS SDK is detected. Nothing is copied or
exported; the workflow references Xcode's resources in place:

- **SDK input:** Xcode's `iPhoneOS.sdk` (and `iPhoneSimulator.sdk` for simulator builds),
  resolved through the selected developer directory.
- **Linker tooling:** Xcode's `ld`/`ld-prime`, `libtool`, and `dsymutil` from the Xcode
  toolchain and platform developer directories.
- **Host Swift:** Xcode's bundled `swift` (decision 3). `doctor` and the packer resolve
  the toolchain through the same selected developer directory.
- **Build metadata:** the SDK version, Xcode version/build, and toolchain identifiers are
  read from Xcode's own metadata (`SDKSettings.json`, `version.plist`, toolchain
  `swiftc --version`), and the packer injects the same build-system Info.plist keys it
  injects today (`DTPlatformName`, `DTPlatformVersion`, `DTSDKName`, `DTXcode`,
  `DTXcodeBuild`, `DTCompiler`; `BuildMachineOSBuild` remains never invented).
- **No artifact bundle.** If a `stupid-app` bundle happens to be imported while in
  Mode A, `doctor` warns that it is unused and consumes space, but the mode does not
  fail.

### Mode B: Xcode-absent

Active when no Xcode installation is detected. This is the original "avoid Xcode on Mac"
case and reuses the existing Linux-style flow:

- **SDK input:** the imported device-only artifact bundle (`stupid-app sdk import`),
  which carries a macOS-hosted Darwin toolset produced by `sdk export --host <mac-triple>`
  on any Xcode-equipped Mac.
- **Host Swift:** a swiftly-installed swift.org toolchain (same mechanism as Linux).
- **Simulator:** unsupported (simulators require Xcode).
- Everything else (sign, device, release) is identical to Mode A once the macOS device
  stack lands.

### Transition

A Mode A user who later removes Xcode performs the one-time export/import from any
Xcode-equipped Mac before removal (or afterwards from another Mac) and continues in
Mode B with the same project and credentials. The two modes produce equivalent signed
artifacts because they feed the same signing and release pipeline; only the SDK input and
host Swift differ.

## Work Areas

### 1. Xcode detection and in-place SDK resolution (Mode A)

- Add a host-capability probe that determines whether a usable Xcode (with an iPhoneOS
  SDK) is present, resolving the selected developer directory the same way `xcode-select`
  does but without depending on `xcrun`.
- Add an in-place SDK-resolution mode in `BuildCore` used in Mode A: the existing
  synthetic-package planner builds via Xcode's `swift` with an explicit
  `-sdk <iPhoneOS SDK path>` and `-target arm64-apple-ios`, reusing the existing
  `-platform_version` injection so `LC_BUILD_VERSION` reports the real SDK version.
  The toolset (`-use-ld=lld`) is not used in Mode A; Xcode's own linker is selected.
- `SDKVersion.resolve` branches by mode: Mode A reads the Xcode SDK version in place;
  Mode B reads the imported bundle manifest. The current macOS `xcrun` fallback becomes
  Mode-A-only and must fail loudly in Mode B.

### 2. Simulator run loop (Mode A)

- Add the `arm64-apple-ios-simulator` target triple to the planner and packer (Intel
  `x86_64-apple-ios-simulator` is deferred with the Intel host matrix). Simulator builds
  use Xcode's `iPhoneSimulator.sdk` in place, build an unsigned `.app`, then ad-hoc sign
  it exactly as Xcode's "Sign to Run Locally" does.
- Add `stupid-app run --simulator [--udid <sim-udid>]` (plus a way to list available
  simulators, e.g. `stupid-app simulators`), implemented with `xcrun simctl`: list/boot
  the runtime, install the `.app`, launch, and report status.
- **Decision: simulator signing.** Simulator apps are ad-hoc signed, which is the normal,
  required mode for simulator execution and is not an intermediate pass in any
  device/release pipeline; the real-certificate invariants for device and App Store
  builds are unchanged. Ad-hoc simulator signing uses the project-owned signer where
  feasible and `codesign -s -` only within this scoped exception.
- **Scoped Apple-tooling exception.** `simctl` is the one product use of Apple runtime
  tooling and is acceptable because simulators cannot exist without Xcode. Simulator
  `.app` output is never a device or release artifact.

### 3. macOS-hosted Darwin tools for Mode B bundles

The Xcode-absent bundle requires macOS-run binaries of the Mach-O linker, `libtool`, and
`dsymutil`. The source is decided (decision 5):

- **Pinned open-source LLVM build.** Build and pin a macOS revision of `lld`'s
  `ld64.lld` (`swift-llvm`), `llvm-libtool-darwin`, and `dsymutil` (`swift-tools`),
  mirroring the Linux `darwin-tools` pin exactly: checksummed, auditable, Apache-2.0 with
  LLVM exceptions. No upstream publishes these today, so the exporter validates a
  project-built reference first, records provenance and licensing, and then distributes
  the pinned binaries.

The toolset schema already supports naming `linker`, `libtool`, and `dsymutil` paths.
`DarwinTools` gains a macOS-hosted source set selected by `*-apple-macosx` host triples;
unsupported archs continue to fail loudly. The `--host` option help text is updated.
This work is Mode-B-only and ordered after the Mode A path (decision 4).

### 4. Host Swift and Mode B toolchain

Mode A uses Xcode's `swift`. Mode B uses a swiftly-installed swift.org toolchain; if that
toolchain proves to require Command Line Tools to operate on macOS at all, CLT is
accepted as a documented Mode B prerequisite (decision 6; CLT is not Xcode and is a
materially smaller dependency). `doctor` resolves which compiler is active and checks the
bundle's Swift major/minor requirement against it.

### 5. macOS TUN, routing, and the privileged helper (shared)

`run --network` and the USB CoreDevice tunnel forward IPv6 packets through a TUN
interface. macOS has no `/dev/net/tun`; it uses `utun` interfaces. **Implemented (Gate
M3):**

- The `CTUN` Darwin backend connects the `com.apple.net.utun_control` kernel-control
  socket (modern macOS has no static `/dev/utunN` nodes), reads the assigned interface
  name back through `UTUN_OPT_IFNAME`, assigns the IPv6 address and `/64` prefix via
  `SIOCAIFADDR_IN6`, sets the MTU via `SIOCSIFMTU`, brings the link up via
  `SIOCSIFFLAGS`, and installs the `/128` server route through the `AF_ROUTE` routing
  socket.
- macOS `utun` packets carry a 4-byte big-endian protocol-family header
  (`AF_INET6` = `00 00 00 1e`); both C tunnel relays (`CCoreDeviceTLS`,
  `CLockdownTLS`) read/write packets through `stupid_app_tun_relay_read`/`write`,
  which strip/prepend that header on macOS and are raw passthrough on Linux.
- Keep the exact existing privilege boundary: build and signing unprivileged; TUN/route
  lifetime owned by the `coredevice-helper` subcommand invoked through an explicit
  `--sudo` boundary. macOS admin users can `sudo`; the helper must not silently elevate.
  Empirically, utun creation requires root on macOS (the kernel-control connect returns
  `EPERM` unprivileged, identical to pymobiledevice3's `pytun`), so `run --network`
  routes through a new `coredevice-helper run-network` subcommand on macOS while Linux
  keeps the in-process path with `cap_net_admin`.
- Preserve deterministic teardown: interface and route removal on success, timeout,
  cancellation, or controller death, with no collision with system `utunN` interfaces.

### 6. Process-group cleanup on Darwin (shared)

`ProcessRunner.stop` must reach descendants. Foundation/Darwin `Process` does not make the
child a process-group leader, so the Linux `kill(-pid)` approach is unsafe on macOS.
**Implemented (Gate M3):** Darwin launches use `posix_spawn` with
`POSIX_SPAWN_SETPGROUP` (pgroup 0: the child becomes its own group leader), so
`kill(-pid)` reaches descendants; the Linux path is unchanged. The acceptance is the
existing one: after timeout or cancellation, no helper process, descendant, tunnel, or
interface survives.

### 7. usbmuxd and USB operations on macOS (shared)

Use the built-in `/var/run/usbmuxd`. Verify native discovery, pair-record access, fresh
lockdown pairing, AFC installation, and CoreDevice launch against the daemon. No MTU
patch is needed because macOS has no USBIP boundary. Document any macOS-specific prompts
(USB accessory access, local-network permission for mDNS/tunnels). **Implementation
status (Gate M3): native discovery, pair-record access, lockdown session TLS, AFC, and
CoreDevice launch are verified against the built-in daemon; `device pair --usb` and
`run --usb` are physically qualified.**

### 8. OpenSSL 3 on macOS (shared)

- Homebrew `openssl@3` is the accepted, documented macOS runtime dependency (decision 7);
  the package already lists it as a provider.
- Wire the build so the `stupid-app` executable runs against the Homebrew dylib (rpath),
  and add a `doctor` check for OpenSSL 3 presence/version on macOS. **Status: the build
  links the Homebrew dylib and `doctor`'s Native CoreDevice TLS check validates OpenSSL
  3 on every host; the deployment-target linker warning is documented and accepted for
  tests.**
- Record the already-known deployment-target linker warning and resolve it (raise the
  package's macOS deployment target or accept the warning for tests only).
- Bundling/static-linking OpenSSL 3 to drop the Homebrew runtime dependency remains a
  later reconsideration, not a requirement.

### 9. doctor macOS checks (shared)

Add macOS equivalents under an `#if os(macOS)` (or `canImport(Darwin)`) gate:
**Implementation status (Gate M3): the usbmuxd-socket and utun/`--sudo` checks are
implemented; the mode, SDK, and OpenSSL checks were already platform-neutral.**

- Xcode presence and the active mode (A or B); in Mode A, that the iPhoneOS SDK and
  toolchain `swift` are present; in Mode B, that an imported compatible bundle and host
  Swift are present.
- OpenSSL 3 availability/version (reuses `CoreDeviceTLSConnection.validateOpenSSL`).
- `utun` availability and route privilege for the network path.
- Built-in usbmuxd socket presence for the USB path.
- A Mode A warning when an imported bundle is installed but unused.

Keep the Linux TUN/usbmuxd checks Linux-gated.

## Proof Gates

### Gate M0: Xcode-present build proof (Mode A)

On a clean Mac with Xcode installed:

1. Build `stupid-app` from source with Xcode's bundled `swift`.
2. `stupid-app doctor` reports Mode A active with the in-place iPhoneOS SDK.
3. `stupid-app new AcceptanceApp` and `stupid-app build` produce an ARM64 iOS Mach-O with
   the real `LC_BUILD_VERSION` SDK value, using Xcode's SDK and linker in place, without
   creating or importing any artifact bundle.

Exit condition: a clean macOS host reproducibly builds an unsigned minimal SwiftUI app
from Xcode's resources with no space duplication. This resolves the mode-detection and
in-place SDK questions first.

### Gate M1: Simulator run loop

On the same clean Mac, with at least one simulator runtime installed:

1. `stupid-app simulators` lists the available runtimes.
2. `stupid-app run --simulator` builds, installs, launches, and reports status on a local
   simulator; the app runs.
3. A fresh build repeats without residual processes.

Exit condition: the app launches on a local simulator through `simctl`, with the scoped
ad-hoc signing exception recorded.

### Gate M2: Xcode-present release

On the clean Mac, `stupid-app release archive` produces a distribution-signed IPA and
`stupid-app release upload --wait` processes to `VALID`/TestFlight readiness; the exact
artifact passes macOS `codesign --verify --strict` and installs/launches through
TestFlight.

Exit condition: App Store Connect reports the macOS-produced build valid and TestFlight
installs it. This re-qualifies the native signer for a new producing host.

### Gate M3: Xcode-present device deployment

On the clean Mac with a physical iPhone:

1. `device pair --usb` completes native lockdown pairing and CoreDevice remote-pair
   bootstrap through the built-in usbmuxd and the new utun backend. **Qualified on this
   Mac (2026-08-18).**
2. `run --usb` installs and launches through the USB tunnel. **Qualified on this Mac
   (2026-08-18): native install + CoreDevice launch, no residual processes/interfaces.**
3. `run --network --udid <udid>` installs and launches physically unplugged, three
   consecutive runs, with zero residual helper processes, interfaces, or routes after
   each run. **In progress:** the network path now runs through the privileged
   `coredevice-helper run-network` subcommand; discovery, Pair-Verify, the tunnel, and
   install work under root, but the AppService launch over the tunnel intermittently
   times out and needs relay debugging before the three unplugged runs can be claimed.

Exit condition: the wireless acceptance criteria run on macOS with no leftover state.
This proves the shared macOS device stack once.

### Gate M4: Xcode-absent path (Mode B)

On a clean Mac with no Xcode (CLT absent initially; add only if proven necessary):

1. Export a macOS-host SDK bundle on an Xcode-equipped Mac; import it here with
   `sdk import`; `doctor` reports Mode B active.
2. `build` reproduces the M0 artifact via the bundle's Darwin tools and swiftly host
   Swift.
3. `release archive` + `release upload --wait` process to `VALID`/TestFlight readiness;
   the device run from M3 repeats.

Exit condition: the complete workflow runs on a Mac with no Xcode, reusing the shared
device stack and the qualified signing/release pipeline.

### Gate M5: Productization

- `doctor` macOS checks (work area 9) and the Mode-aware SDK fallback (work area 1) land.
- A macOS clean-host setup/recovery document is added beside
  `docs/clean-host-setup.md`.
- README, engineering handover, and command help reflect macOS as a supported host and
  the two modes.

Exit condition: all acceptance criteria run through stable CLI commands on clean macOS
hosts in both modes.

## Risks And Open Decisions

- **Xcode coupling in Mode A.** Builds depend on a specific Xcode version's SDK and
  toolchain; a user upgrading Xcode changes SDK version and metadata. Mode A must read
  version metadata from Xcode itself and record it in the release manifest.
- **Host Swift toolchain in Mode B.** The swift.org macOS toolchain may require CLT for
  its own bootstrapping; this is accepted if empirically required (decision 6) and Mode B
  then means "no Xcode", not "no Apple tooling". Confirmed empirically at Gate M4.
- **macOS Darwin-tool distribution.** The pinned LLVM `ld64.lld`/`libtool`/`dsymutil`
  build (decision 5) has no published upstream binaries, so this project produces and
  distributes the first pinned reference; licensing (Apache-2.0 with LLVM exceptions) and
  provenance must be recorded. (M4)
- **Simulator signing.** Ad-hoc simulator signing is a deliberate, scoped exception to
  the real-certificate invariants; it must never leak into a device or release path.
- **Simulator runtime availability.** `run --simulator` depends on an installed runtime
  and a booted/bootable device; missing runtimes must surface as actionable diagnostics.
- **utun naming and teardown.** Collisions with system interfaces, and route/interface
  cleanup across abrupt controller death, need physical-device qualification.
- **Process-group semantics on Darwin.** Descendant cleanup behavior differs from Linux
  and must be proven under timeout and cancellation.
- **macOS local-network permissions.** Firewall/TCC prompts (local network, USB
  accessory access) may require a one-time user action and should surface as actionable
  diagnostics rather than silent timeouts.
- **OpenSSL 3 runtime.** Homebrew `openssl@3` is the accepted runtime dependency
  (decision 7); version and update cadence must be stated for supported macOS versions.
  Bundling later remains optional.
- **macOS version and architecture matrix.** First supported host is
  `arm64-apple-macosx` on macOS 14+ (decision 8); Intel hosts and
  `x86_64-apple-macosx` Mode B bundles are deferred. Simulator target is
  `arm64-apple-ios-simulator`.
- **Clean-host requirement.** Whether the macOS proof gates need a disposable clean Mac
  or may run on a developer machine with documented state is still open (decision 9).
- **Legal.** The SDK export license gate in the handover applies unchanged. The chosen
  pinned-LLVM toolset (decision 5) avoids proprietary Apple-tool-derived binaries.
- **Relative size** (points, not calendar estimates):

  | Work area | Points |
  | --- | ---: |
  | M0 Xcode detection + in-place SDK build path | 6-10 |
  | M1 simulator run loop (target triple + simctl) | 6-9 |
  | M2 macOS-produced release re-qualification | 2-4 |
  | M3 macOS TUN/utun + routing + privileged helper + device re-qualification | 10-16 |
  | Process-group cleanup on Darwin | 3-5 |
  | usbmuxd/USB verification on macOS | 3-6 |
  | OpenSSL 3 on macOS (rpath, doctor, decision) | 3-5 |
  | M4 macOS-host Darwin tools + Mode B bundle export/import | 8-13 |
  | doctor macOS checks + mode-aware SDK fallback | 3-5 |
  | Clean-host setup docs + acceptance run | 3-6 |

## Out Of Scope

Raw-USB transport replacement, simulator support in Mode B, Windows, changing the SDK
bundle format, and removing the one-time Xcode export for Mode B are out of scope.
