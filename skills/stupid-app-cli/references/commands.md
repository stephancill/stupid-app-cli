## Privilege boundary

CoreDevice network runs and USB CoreDevice pairing create a TUN interface and
need `CAP_NET_ADMIN`. The CLI never elevates implicitly. Two supported
arrangements:

- **Setcap on the binary (proof-host arrangement):** the whole run stays
  unprivileged and the binary itself is granted the capability:
  `sudo setcap cap_net_admin=ep .build/debug/stupid-app`. Every rebuild wipes
  the capability; re-apply it.
- **Scoped sudo grant (product arrangement):** install the binary root-owned and
  grant only the helper subcommand in sudoers, then pass `--sudo /usr/bin/sudo`:
  `iosdev ALL=(root) NOPASSWD: SETENV: /usr/local/bin/stupid-app coredevice-helper *`.
  Never grant a broad `NOPASSWD: ALL`.

## Command reference

Exact command surface for `stupid-app`. Run `stupid-app --help` or
`stupid-app help <command>` for the authoritative version; this reference tracks
the current build.

## Top level

```text
stupid-app --version   # -v: print the product version + host Swift compiler line
stupid-app <subcommand>
```

Subcommands: `doctor`, `new`, `sdk`, `build`, `credentials`, `signing`,
`devices`, `device`, `run`, `simulators`, `release`, `coredevice-helper`.

`coredevice-helper` is the privileged native CoreDevice subcommand; it is
normally invoked by `run`/`device pair` with `--sudo` and should not be called
directly.

## doctor

```text
stupid-app doctor [--project <dir>] [--home <cred-dir>] [--sdk-id <id>] [--swift <path>] [--sudo <path>]
```

Checks the host toolchain, imported SDK compatibility, native signing trust,
OpenSSL 3.x, CoreDevice helper, credential/identity/pairing presence and
permissions, Linux TUN/usbmux prerequisites, and project config. Required
failures exit unsuccessfully; incomplete workflow state is a warning. Never
reads or prints secret values. `--project` defaults to `.` and is used to
validate a `stupid-app.yml` project.

## new

```text
stupid-app new <name> [--bundle-id <id>] [--deployment-target <ver>] [--icon <png>] [--output <dir>]
```

Scaffolds a SwiftPM/SwiftUI iOS project. `<name>` is the project/product name.
`--bundle-id` is the exact identifier (e.g. `net.example.acceptance-app`);
`--deployment-target` defaults to `17.0`; `--icon` copies a square source PNG to
`Resources/AppIcon.png`; `--output` defaults to the current directory.

## sdk

```text
stupid-app sdk export --host <triple> [--xcode <path>] [--target arm64-apple-ios] [--output <dir>] [--scratch <dir>]
stupid-app sdk import <archive> [--expected-sha256 <sha256>] [--swift <path>]
```

- `export` (macOS only) writes a device-only, checksummed
  `stupid-app-ios-<target>-<host>.artifactbundle.tar.zst`. `--xcode` defaults to
  `/Applications/Xcode.app`. Linux host triples download the pinned Linux
  darwin-tools; macOS host triples stage pinned Homebrew LLVM tools for the
  Xcode-absent path.
- `import` verifies the archive SHA-256 (when given) and every declared file
  checksum, rejects unsafe paths, checks host triple and Swift compatibility,
  then registers the bundle with `swift sdk install` under artifact ID
  `stupid-app-ios`.

## build

```text
stupid-app build [--configuration debug|release] [--sdk-id <id>] [--sdk-version <ver>] [--swift <path>]
```

Builds an unsigned `.app` (Xcode SDK in place on Xcode-present macOS, otherwise
the imported bundle). `--configuration` defaults to `debug`. `--sdk-version`
overrides the SDK version reported in `LC_BUILD_VERSION`. Uses the `stupid-app-ios`
artifact by default.

## credentials

```text
stupid-app credentials add [--key-id <id>] [--issuer-id <id>] [--p8 <path>] [--team-id <TEAM>] [--home <dir>]
```

Stores the App Store Connect API key and developer team identity. Default home
is `~/.stupid-app/credentials`. Files are owner-only (`0600`) in a `0700`
directory. Equivalent options accepted by `signing setup`.

## signing

```text
stupid-app signing setup <options>
```

The single provisioning command. Options:

- `--kind <distribution|development>` — repeatable; defaults to both kinds.
- `--bundle-id <id>` — repeatable; defaults to the bundle ID in `stupid-app.yml`
  when run in a project directory.
- `--profile-name <name>` — profile name prefix (defaults to bundle ID).
- `--udid <udid>` — physical device UDID; development setup runs only when given.
- `--device-name <name>` — device display name for registration.
- `--import-key <pem>` / `--import-cert <pem>` / `--cert-id <id>` — import an
  existing identity and its App Store Connect certificate resource ID instead of
  minting one.
- `--from-xcode` — macOS only; reuse a Keychain identity and Xcode-managed
  provisioning profile for the exact bundle.
- `--key-id`, `--issuer-id`, `--p8`, `--team-id` — store ASC credentials when
  provided (skips a separate `credentials add`).
- `--home <dir>` — credential store directory.

## devices

```text
stupid-app devices          # alias for `list`
stupid-app devices list     [--home <dir>]
stupid-app devices add --udid <udid> [--name <name>] [--home <dir>]
```

Lists or registers App Store Connect devices. `--name` defaults to `iPhone`.

## device

```text
stupid-app device pair --usb [--udid <udid>] [--sudo <path>] [--usbmux <addr>] [--timeout <sec>] [--replace-lockdown-record] [--home <dir>]
stupid-app device crash [--path <file>] [--udid <udid>] [--filter <name>] [--network] [--sudo <path>] [--json] [--home <dir>]
```

`device pair` bootstraps lockdown trust natively and then CoreDevice remote pairing over
USB. `--usbmux` accepts a Unix socket or `HOST:PORT`. `--timeout` defaults to 30
seconds — raise it (e.g. `180`) when the on-device Trust dialog needs time.
`--replace-lockdown-record` writes a fresh lockdown trust record instead of
reusing the existing one. The privileged CoreDevice pair requires `--sudo` on
a capable host.

`device crash` parses an iOS crash report and prints a human-readable summary
(termination namespace/code/reason, exception, application-specific detail) or,
with `--json`, machine-readable fields. It classifies watchdog/resource-limit
terminations (jetsam, `cpu usage`, memory/exc_resource) so a launch crash such as
a `SIGKILL` from excessive logging is surfaced directly.

- With `--path <file>` it parses a local `.ips` file.
- With `--udid <udid>` (a usbmux serial/UDID) it pulls the newest matching report
  from the device's crash-report service over USB (native lockdown + AFC, no host
  tool or privilege needed) and parses it. `--filter <name>` is a substring against
  report file names (e.g. `CrashTester`); the newest by embedded timestamp is
  chosen.
- Adding `--network` pulls over the wireless CoreDevice tunnel instead, eventually
  routed through the `coredevice-helper crash-network` subcommand. On macOS the
  network tunnel needs the privileged TUN, so pass `--sudo <path>`; on Linux the
  tunnel stays in-process and needs no privilege.
- `--home` points at the credential store (default `~/.stupid-app/credentials`).

## run

```text
stupid-app run [--usb|--network|--simulator] [--udid <udid>] [--sdk-id <id>] [--swift <path>] [--sudo <path>] [--usbmux <addr>] [--home <dir>]
```

Builds, signs once (Apple Development), packages, installs, and launches.

- `--usb` — install over a USB-connected device.
- `--network` — discover over mDNS, open a CoreDevice tunnel, install, launch
  (device must be paired via `device pair --usb` beforehand).
- `--simulator` — macOS Xcode-present only; builds for the simulator SDK,
  ad-hoc signs, boots, installs, launches via `simctl`.
- `--udid` auto-selects when omitted. Requires privileged helper access for
  network runs.

## simulators

```text
stupid-app simulators
```

Lists simulator runtimes and devices (macOS Xcode-present).

## release

```text
stupid-app release archive [--sdk-id <id>] [--swift <path>] [--sdk-version <ver>] [--home <dir>] [--output <dir>]
stupid-app release upload [--wait] [--ipa <path>] [--app-bundle-id <id>] [--home <dir>] [--output <dir>] [--poll-interval <sec>] [--sdk-id <id>] [--swift <path>]
stupid-app release status [--live] [--home <dir>] [--output <dir>]
stupid-app release new-build [--home <dir>] [--bundle-id <id>] [--build-number <n>]
stupid-app release bump [--build-number <n>] [--shallow]
```

- `archive` — release-configure build, one real Apple Distribution signing pass
  (no timestamps), native `Assets.car`, App Store profile embedded, IPA packaged
  to `./.release/<product>.ipa` (override with `--output`).
- `upload` — resolves the exact app by bundle ID and version/build number,
  rejects duplicate build numbers, uploads via the Build Upload APIs, and with
  `--wait` polls until internally TestFlight-ready (`VALID` /
  `READY_FOR_BETA_TESTING`). Writes the public-safe release manifest. `--ipa`
  and `--output` default to `./.release`. A build number that already exists
  (e.g. from a killed earlier run) is reported as an already-uploaded state
  pointing at `release status --live`, not a packaging failure.
- `status` — reports the recorded last release; `--live` queries App Store
  Connect for the current processing/beta state of the resolved build.
- `new-build` — suggests the next integer build number based on the latest
  uploaded build, or increments `--build-number` when given.
- `bump` — increments `CFBundleVersion` in `Info.plist` and every bundled
  extension's plist in lockstep (a deep release shares one build), or sets it to
  `--build-number`. `--shallow` bumps only the app plist.