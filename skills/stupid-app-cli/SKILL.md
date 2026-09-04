---
name: stupid-app-cli
description: "Operate the stupid-app CLI for iOS development without Xcode on Mac or Linux. Use to scaffold (new), export/import the iOS Swift SDK (sdk export/import), provision ASC credentials/signing (credentials add, signing setup), build (build), register devices, pair (device pair), and run/install/launch over USB, network, a simulator, or on-Mac (run --usb/--network/--simulator/--mac) — or release with preflight/archive/upload/status/new-build/bump and external TestFlight (external-beta, beta-group, beta-notes). Also diagnose with doctor."
---

# stupid-app CLI

`stupid-app` creates, builds, signs, installs, launches, and releases iOS
SwiftPM/SwiftUI apps without Xcode or macOS at runtime. Linux is the production
host; macOS is an additive host either with Xcode present or using an imported
SDK bundle. Distribution uses real Apple certificates and public App Store
Connect APIs only.

`stupid-app --version` (or `-v`) prints the product version and the host Swift
compiler line; bare `stupid-app` prints the top-level help.

This skill is distributed with the CLI binary. It is self-contained; the
repository's `docs/` files hold deeper architecture detail when you are working
from a source checkout.

## Ground rules

- Follow the product invariants. Never pseudo-sign or ad-hoc sign an app as an
  intermediate step. Every device or release build gets exactly one real Apple
  signing pass. Do not rewrite or prefix configured bundle identifiers.
- Prefer failing loudly. If a required credential, SDK, profile, signer, or host
  dependency is missing or invalid, stop with an actionable error. Do not fall
  back to another tool, Xcode, `altool`, Transporter, or pseudo-signing.
- Never print, log, or commit secrets: ASC `.p8` keys, signing private keys,
  PKCS#12 files, provisioning profile contents, pairing records, JWTs, or
  presigned upload URLs. Credentials live in `~/.stupid-app/credentials`
  (directory `0700`, files `0600`, plaintext, atomic writes).
- The CLI never elevates silently. Privileged CoreDevice TUN operations run
  through a helper subcommand; pass `--sudo <path>` to authorize it.
- Version 1 supports one SwiftPM library product with code-based SwiftUI, plus an
  optional `extensions:` list in `stupid-app.yml` for bundled `PlugIns/*.appex`
  extensions (e.g. a WidgetKit extension) sharing App Groups. Xcode project inputs,
  storyboards, un-compiled asset catalogs, Core Data models, ExtensionKit products,
  and other unsupported resources must fail loudly.

## Environment requirements

- **Linux (production):** x86_64 Ubuntu 24.04 LTS. Swift 6.2.x toolchain, the
  imported `stupid-app-ios` Swift SDK (registered via `swift sdk install`),
  OpenSSL 3.x (`libssl-dev`), `zstd`, and `zip`/`unzip`. CoreDevice networking
  needs `/dev/net/tun` and `CAP_NET_ADMIN` (see pairing/run below). USB installs
  need a qualified MTU-patched `usbmuxd` when running under WSL USBIP.
- **macOS:** Apple Silicon macOS 14+. Either Xcode-present (builds in place) or
  Xcode-absent (uses an imported bundle). `run --simulator` is Xcode-present-only.
- **Physical device:** a paid Apple Developer Program account, an iPhone with
  Developer Mode enabled, unlocked/on-screen during pairing and install, and on
  the same LAN as the deployment host for network runs.

## First-time setup

Verify the host first: run `stupid-app doctor` and resolve every failure.

```bash
# 1. Import the pre-exported SDK bundle (Linux) or export one (macOS), see below.
stupid-app sdk import stupid-app-ios-arm64-apple-ios-x86_64-unknown-linux-gnu.artifactbundle.tar.zst --expected-sha256 <sha256>

# 2. Store the App Store Connect team API key + team ID, then provision identities
#    and profiles. Passing the credential options to `signing setup` skips this
#    step entirely.
stupid-app credentials add --key-id <id> --issuer-id <id> --p8 <key.p8> --team-id <TEAM>
stupid-app signing setup --kind distribution --bundle-id net.example.app
stupid-app signing setup --kind development --bundle-id net.example.app --udid <udid> --device-name "<name>"

# 3. Verify again: 0 failures.
stupid-app doctor
```

One-shot equivalent for a fresh user:

```bash
stupid-app signing setup --key-id <id> --issuer-id <id> --p8 <key.p8> --team-id <TEAM> \
  --bundle-id net.example.app --udid <udid>
```

`signing setup` is the single provisioning command. `--kind` is repeatable and
defaults to both distribution and development; development runs only when
`--udid` is given. When run in a project directory, `--bundle-id` defaults to
all bundle IDs in `stupid-app.yml` (the app plus every configured extension), and
each bundle's declared `capabilities:` entries are enabled on that bundle ID via
the API. ASC credentials may also come from environment
variables `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_PATH`, and
`DEVELOPER_TEAM_ID`.

Development setup reconciles the profile set instead of reusing a stale one: if
no profile provisions the requested `--udid`, it creates a replacement that also
provisions every previously provisioned device and retires the stale remote
profiles only after the replacement is stored and validated. Profiles are stored
at a canonical `<kind>/<bundle-id>.mobileprovision` path and located by content
(bundle + kind), so re-runs on a new phone don't need the manual delete/rename/
copy dance. `--profile-name` is a display-name prefix, not the full name.

On macOS, reuse what Xcode already manages instead of minting credentials:

```bash
stupid-app signing setup --kind distribution --bundle-id net.example.app --from-xcode
```

This imports the matching Keychain identity and Xcode-managed provisioning
profile; it does not make the Keychain a signing-time dependency.

## SDK export and import

SDK bundles are exported one-time on a Mac from an installed Xcode and consumed
on a Linux host.

```bash
# macOS, once per (Xcode, host triple) pair:
stupid-app sdk export --xcode /Applications/Xcode.app --host x86_64-unknown-linux-gnu --target arm64-apple-ios --output .
# Produces stupid-app-ios-arm64-apple-ios-<host>.artifactbundle.tar.zst + SHA-256.

# Linux, per host:
stupid-app sdk import <archive> --expected-sha256 <sha256>
swift sdk list   # -> stupid-app-ios
```

The importer verifies the archive and every declared file checksum, rejects path
traversal and unsafe entries, checks host-triple and Swift compatibility, then
registers with `swift sdk install`. Alert the user if they attempt to run
`run`/`build`/`release` without an imported SDK; there is no automatic download.

## Daily workflows

### 1. Create a project

```bash
stupid-app new AcceptanceApp --bundle-id net.example.acceptance-app
cd AcceptanceApp
```

This scaffolds a SwiftPM package, `stupid-app.yml`, `Info.plist`,
`App.entitlements`, and SwiftUI sources. Pass `--icon <square-png>` to seed
`Resources/AppIcon.png` (and the `iconPath` config key) and
`--deployment-target` to set the minimum iOS version (default `17.0`). The
default scaffold has no icon, which is fine for building and running but not for
App Store Connect upload; create release projects with `--icon` or add a square
PNG and `iconPath` before archiving. New scaffolds declare
`ITSAppUsesNonExemptEncryption=false`; change it if the app uses non-exempt
encryption.

`stupid-app.yml` (project config, version 1; `iconPath` is present only when
`--icon` was given):

```yaml
version: 1
product: AcceptanceApp
bundleID: net.example.acceptance-app
deploymentTarget: "17.0"
infoPath: Info.plist
entitlementsPath: App.entitlements
iconPath: Resources/AppIcon.png
# Optional bundled app extensions (each becomes a PlugIns/<product>.appex):
# extensions:
#   - product: MyWidgetExtension
#     bundleID: net.example.acceptance-app.widget
#     infoPath: WidgetExtension-Info.plist
#     entitlementsPath: WidgetExtension.entitlements
#     appIntentsMetadata: WidgetMetadata/Metadata.appintents
# App Store Connect capabilities to enable on a bundle ID. Each entry maps a
# source entitlement key to the portal capability type that authorizes it; add an
# entry here for every entitlement that needs portal provisioning (no code
# change). Example — push notifications on the app and App Groups on the app plus
# each extension:
# capabilities:
#   - entitlementKey: aps-environment
#     type: PUSH_NOTIFICATIONS
#   - entitlementKey: com.apple.security.application-groups
#     type: APP_GROUPS
```

Extensions share the app's signing identity per kind, are provisioned as their own
bundle IDs (`signing setup --bundle-id` per bundle, or read all from `stupid-app.yml`),
and are signed leaf-first during `run`/`release archive` with their own profiles and
entitlements. Entitlements are profile-gated pass-through: every source entitlement is
signed it exists, and anything the profile does not authorize fails loudly, so the
supported-capability set stays open without per-capability code. A project with no
entitlements file needs no placeholder — when `entitlementsPath` is unset and
`App.entitlements` is absent, signing treats the source as empty.
Capability *enablement* is declared per bundle in `stupid-app.yml` under `capabilities:`
(the app and each extension may each list entries): `signing setup` enables each declared
capability via the API on that bundle ID. Declaring a capability is required — there is no
implicit App Groups/AutoFill/Push enablement — so a capability whose source entitlement is
signed without a matching `capabilities:` entry fails loudly at the profile-authorization
gate. Concrete resources such as App
Group identifiers or the sandbox APNs environment are one-time Developer Portal
associations that signing enforces loudly until the downloaded profile authorizes them.

### 2. Build an unsigned app

```bash
stupid-app build                 # debug
stupid-app build --configuration release
```

Produces an unsigned `.app` with a native `Assets.car` and the real SDK version
in `LC_BUILD_VERSION`. On Xcode-present macOS hosts the build runs against
Xcode's SDK in place instead of an imported bundle. Use `--sdk-id` to select an
imported SDK (default `stupid-app-ios`) and `--swift` to point at a specific
`swift` executable.

### 3. Development run over USB

```bash
stupid-app run --usb [--udid <udid>] [--usbmux /var/run/usbmuxd]
```

Builds a debug app, derives development entitlements (`get-task-allow=true`),
signs once with the stored Apple Development identity, packages, installs, and
launches. Before building, `run` resolves the target device and preflights every
development profile (app + extensions) against that device's UDID, team, and
bundle ID, so a stale or wrong profile fails loudly with re-provisioning
instructions instead of after an expensive build. Prefer `--usbmux` explicitly
when the socket is non-standard. Under
WSL USBIP the MTU-patched `usbmuxd` service must be running or large installs
stall. The device must be unlocked during install.

### 4. Pair once, then run wirelessly

```bash
# Inspect what the host knows about its devices (USB + saved network pairings):
stupid-app device list

# Requires USB. Confirm the on-device Trust dialog; raise --timeout if it
# expires (e.g. --timeout 180) before the dialog is answered.
stupid-app device pair --usb [--timeout 180]

# Then, with the phone off USB and on the same LAN:
stupid-app run --network --udid <udid> [--sudo /usr/bin/sudo]
```

Pairing stores owner-only records under the credential directory. Network runs
discover the device over mDNS, open a CoreDevice tunnel, install, verify the
bundle, and launch. The network path needs the TUN privilege boundary (setcap on
the binary or a scoped sudo grant — see `Privilege boundary` in
`references/commands.md` and `docs/clean-host-setup.md`).
`--replace-lockdown-record` regenerates the lockdown trust during pairing.

### 5. macOS simulator

```bash
stupid-app simulators
stupid-app run --simulator [--udid <udid>]
```

Xcode-present-only. Lists runtimes/devices and builds for the simulator SDK,
ad-hoc signs, boots, installs, and launches via `simctl`. Simulator ad-hoc
signing embeds a sanitized entitlement override: `keychain-access-groups` and
profile-gated capabilities such as `autofill-credential-provider` are dropped
(they make SpringBoard reject the launch), while
`com.apple.security.application-groups` is preserved for the shared container.
Simulator Keychain access groups are unavailable by design without a
development identity.

### 6. Apple Silicon Mac compatibility run

```bash
# Obtain the local provisioning UDID from System Information, then provision once:
stupid-app signing setup --kind development --udid <mac-provisioning-udid>
stupid-app run --mac
```

This builds and signs the ordinary iOS device binary, creates macOS's
`Wrapper/<app>.app` plus `WrappedBundle` compatibility layout, registers it with
LaunchServices, registers each nested `.appex` with PlugInKit (`pluginkit -a`), and
launches it through UIKitSystem. A nested Safari Web Extension's web content runs in
Safari, but native messaging does not (Safari cannot spawn the iOS appex plugin without
the entitled installer's launchd registration).

### 7. Distribution release

```bash
stupid-app release preflight            # local gates: versions in lockstep + export compliance
stupid-app release bump                 # increment build across app + extensions
stupid-app release bump --marketing     # bump the marketing version (patch) instead
stupid-app release archive
stupid-app release new-build            # suggest the next build number
stupid-app release upload --wait
stupid-app release status [--live]
stupid-app release external-beta   # external TestFlight (group + submit + poll to readiness)
stupid-app release beta-group list      # list beta groups
stupid-app release beta-group create --name <name>
stupid-app release beta-group add-build --group <id> --build-id <id>
stupid-app release beta-group add-tester --group <id> --email <addr>
stupid-app release beta-notes --whats-new "<note>"
```

`release preflight` hard-gates a release locally (no App Store Connect call): it requires
the app's `CFBundleShortVersionString`/`CFBundleVersion` to match every bundled
extension in lockstep and an `ITSAppUsesNonExemptEncryption` Boolean to be declared.
`release upload` runs the same gate before uploading, so the Invalid-bundle
(`ITMS-90062`) and `MISSING_EXPORT_COMPLIANCE` rejection classes fail fast.

`release bump` increments `CFBundleVersion` in `Info.plist` and every bundled
extension's plist in lockstep (or sets a value with `--build-number`; `--shallow`
bumps only the app; `--marketing` bumps `CFBundleShortVersionString` instead). Build
numbers may be dotted (`1.12.3 -> 1.12.4`) as well as plain integers.
`release archive` produces `./.release/<product>.ipa` signed
once with the
Apple Distribution identity and App Store profile, timestamps disabled, with a
native `Assets.car` and build-system Info.plist keys. `release upload --wait`
resolves the exact build by bundle ID + marketing version + build number,
uploads through the public Build Upload APIs, and polls until the build is
internally TestFlight-ready. It writes a public-safe release manifest
(`./.release/release-manifest.json`) with artifact hash, bundle ID, versions,
resource IDs, and states — never secrets. `release status --live` queries App
Store Connect for the current processing/beta state.

`release external-beta` takes an already-uploaded build and makes it externally
testable: it resolves an external beta group (by `--group` id or by name, creating
one as needed), adds the build to it, optionally sets the "What to Test" note, and
submits an external beta review submission, then (by default) waits until external
`IN_BETA_TESTING` — pass `--no-wait` to only create the submission. `release beta-group list/create/add-build/add-tester` manage
external groups and their testers, and `release beta-notes` sets the per-build
"What to Test" note alone. Manual prerequisites the API cannot perform (`create the
App Store Connect app record before the first upload`, and complete the app's Beta
App Description before external review) remain explicit. A missing description is
reported by Apple as `MISSING_BETA_APP_DESCRIPTION`. External beta requires
`DTPlatformBuild`/`DTSDKBuild`/canonical `DTXcode` (packaged since 0.0.10) or App
Store Connect rejects with `BUILD_SDK_NOT_ALLOWED_FOR_EXTERNAL_TESTING`.

## Command reference

The complete command and option reference lives in
[`references/commands.md`](references/commands.md): read it when you need exact
flags, defaults, or help text. Key invariants to remember:

- `release archive` and `run`/`device pair` each need the matching identity and
  profile already provisioned (`signing setup`) and real credentials; otherwise
  they fail loudly.
- `release upload` requires the ASC-keyed store; an `--from-xcode`-imported
  identity without an ASC key is sufficient for archive/run but not upload.
- `doctor` is the first diagnostic for any failure: run it before assuming a
  code or environment bug.

## Troubleshooting and recovery

When a workflow fails, in order:

1. Run `stupid-app doctor` and fix every failure it reports.
2. Confirm the prerequisite that phase needs: imported SDK, provisioned
   identity/profile, credentials, pairing record, TUN privilege, MTU-patched
   usbmuxd for WSL USB installs, unlocked device.
3. For network discovery failures after a rebuild, re-apply the TUN capability
   (`sudo setcap cap_net_admin=ep` on the debug binary) or re-establish the
   scoped sudo grant; then retry.
4. If the pairing record is missing or stale, re-run `device pair --usb`.
5. Check the release manifest and `release status --live` before re-uploading;
   do not reuse a build number that already exists.
6. If App Store Connect rejects an external TestFlight submission with
   `MISSING_BETA_APP_DESCRIPTION`, complete the app's Beta App Description in App
   Store Connect, then rerun `release external-beta`; the existing upload and beta
   group assignment can be reused.
7. If App Store Connect rejects an external TestFlight submission with
   `BUILD_SDK_NOT_ALLOWED_FOR_EXTERNAL_TESTING` or shows "beta version of Xcode",
   inspect the packaged IPA's build-system keys before blaming the toolchain:
   `unzip -p <ipa> Payload/<App>.app/Info.plist | plutil -p -` and check that
   `DTXcode`, `DTXcodeBuild`, `DTPlatformBuild`, `DTSDKBuild`, and `DTSDKName` are
   present and canonical. Since 0.0.10 the packer emits `DTPlatformBuild`/`DTSDKBuild`
   from the SDK's `SystemVersion.plist` build number and encodes `DTXcode` as
   `major*100 + minor*10 + patch`. Older output omitted those keys or encoded
   `DTXcode` incorrectly (e.g. `266` for Xcode 26.6 instead of `2660`), which made
   Apple classify an otherwise valid build as unsupported/beta. Re-export stale
   imported iOS SDK bundles so their `sdk-manifest.json` records `iphoneosSDKBuild`.
8. Inspect a device crash report with `stupid-app device crash` — pass a local
   `--path <file>.ips` or `--udid <phone-udid>` to pull the newest matching
   report directly from the phone over USB (no host tool), optionally `--json`.
   Add `--network` to pull a wireless device over the CoreDevice tunnel (needs
   `--sudo` on macOS for the privileged TUN). It prints the termination
   namespace/reason, exception, and app-specific detail in one pass, and flags
   watchdog/CPU/resource terminations (e.g. `SIGKILL` from excessive logging).

Detailed clean-host setup and recovery procedures live in
`docs/clean-host-setup.md` (Linux/WSL) and `docs/macos-clean-host-setup.md`
(macOS) in the source tree. When the docs and CLI behavior disagree, investigate
and correct the docs rather than silently trusting either side.
