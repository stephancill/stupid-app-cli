# macOS Clean Host Setup And Recovery

This document describes how to bring a macOS host to the point where the full
`stupid-app` workflow runs, in either supported host mode, and how to recover a host
that has drifted. It is the operational companion to
`docs/engineering-handover.md` and `docs/macos-host-support-scope.md`; treat those
documents as the source of truth and update all three together.

macOS support has two mutually exclusive modes selected by Xcode presence:

- **Mode A (Xcode-present):** builds against Xcode's iPhoneOS SDK and bundled `swift`
  in place, with no imported artifact bundle. Simulator support and physical-device
  work are available. This path is trustworthy in the proof sense (gates M0-M3 are
  qualified on a developer Mac).
- **Mode B (Xcode-absent):** builds with an imported device-only artifact bundle and a
  swiftly-installed swift.org toolchain. The macOS-hosted Darwin toolset (pinned LLVM
  `ld64.lld`, `libtool`, `dsymutil`) is gate M4 and is **not yet built or validated**;
  treat Mode B below as the intended procedure pending M4.

A clean macOS host's runtime state is produced entirely by repeatable commands in this
document plus the one-time credentials the operator supplies.

## Prerequisites

- Apple Silicon macOS 14+ (the first supported matrix is `arm64-apple-macosx`).
- The `stupid-app` source tree on the host.
- Homebrew with `openssl@3` installed (a runtime dependency for the native
  CoreDevice TLS stack).
- **Mode A:** an installed Xcode (with an iPhoneOS SDK) plus at least one simulator
  runtime for `run --simulator`.
- **Mode B (pending M4):** a Mac with an imported device-only bundle exported from any
  Xcode-equipped Mac, and a swiftly-installed swift.org toolchain matching the bundle.
- App Store Connect team API key, issuer ID, `.p8`, and team ID.
- A physical iPhone with Developer Mode enabled, on the same LAN, unlocked for pairing.

## Initial Setup Order (Mode A, Xcode-present)

### 1. Toolchain and runtime dependency

```bash
swift build
brew install openssl@3
```

`doctor`'s "Native CoreDevice TLS" check validates OpenSSL 3 on every host. The build
links Homebrew's `libssl`/`libcrypto`; a deployment-target linker warning about the
Homebrew dylib is documented and accepted for tests.

### 2. No SDK import needed

Mode A builds against Xcode's iPhoneOS SDK in place, so there is no `sdk export` /
`sdk import` step. An imported bundle that happens to be present is reported as a
warning by `doctor` and is unused.

### 3. Credentials and signing identities

```bash
stupid-app credentials add
stupid-app signing setup --kind distribution --bundle-id <bundle-id>
stupid-app signing setup --kind development --bundle-id <bundle-id> --udid <udid> --device-name "<name>"
stupid-app signing setup --kind distribution --bundle-id <bundle-id> --from-xcode   # optional: reuse Xcode's identity/profile
```

The credential directory is `~/.stupid-app/credentials`, mode `0700`, secret files mode
`0600`.

Verification: `stupid-app doctor` reports Mode A active and 0 failures. `--from-xcode`
imports an existing Keychain identity and the exact Xcode-managed provisioning profile
for the bundle; it requires the identity's private key to be in an accessible (unlocked)
Keychain and a matching profile in `~/Library/MobileDevice/Provisioning Profiles`.

### 4. Simulator run loop (optional)

```bash
stupid-app simulators
stupid-app run --simulator [--udid <sim-udid>]
```

Requires a simulator runtime and a bootable device; missing runtimes surface as
actionable diagnostics.

### 5. Pairing records

`stupid-app device pair --usb` uses the built-in `/var/run/usbmuxd` (no MTU patch or
daemon provisioning is needed on macOS). It performs native lockdown pairing and the
CoreDevice remote-pair bootstrap, writing an owner-only record under
`~/.stupid-app/credentials/pairing`. A host that already has a `remote_<id>.plist` record
can skip straight to network runs.

Verification: `stupid-app doctor` reports the pairing-records check as `PASS`.

### 6. Privilege boundary for utun

macOS creates `utun` interfaces through a kernel-control socket that requires root
(`com.apple.net.utun_control` returns `EPERM` unprivileged). The CLI never elevates
implicitly; `run --network` routes the TUN/route lifetime through the privileged
`coredevice-helper run-network` subcommand. Support the helper with a scoped sudoers
grant and pass `--sudo`:

```bash
sudo install -o root -g root -m 755 .build/release/stupid-app /usr/local/bin/stupid-app
echo 'USER ALL=(root) NOPASSWD: SETENV: /usr/local/bin/stupid-app coredevice-helper *' \
  | sudo tee /etc/sudoers.d/stupid-app-coredevice
sudo chmod 440 /etc/sudoers.d/stupid-app-coredevice
sudo visudo -c
stupid-app run --network --udid <udid> --sudo /usr/bin/sudo
```

For a proof host using the debug binary, the sudoers grant must be scoped to the current
build path after every rebuild. Do not grant a broad `NOPASSWD: ALL`.

### 7. Health check

```bash
stupid-app doctor
```

A clean Mode A host exits 0. `[WARNING] Project configuration` is expected when run
outside a project directory.

## Initial Setup Order (Mode B, Xcode-absent) — pending M4

Until Gate M4 ships the macOS-hosted Darwin toolset, this procedure is the target, not a
validated path. The intended order:

1. Export a macOS-host bundle on an Xcode-equipped Mac:
   `stupid-app sdk export --host <mac-arm64-triple> --target arm64-apple-ios`.
2. Import it here: `stupid-app sdk import <archive> --expected-sha256 <sha256>`.
3. Ensure the swiftly-installed swift.org toolchain is active; `doctor` reports Mode B
   active and checks the bundle's Swift major/minor against the host toolchain.
4. Simulators are unavailable in Mode B.
5. Credentials, signing, pairing, and the utun privilege boundary are identical to
   Mode A.

## Daily Use

```bash
stupid-app run --network --udid <udid> --sudo /usr/bin/sudo   # Mode A
stupid-app run --simulator [--udid <sim-udid>]                # Mode A
stupid-app release archive
stupid-app release upload --wait
stupid-app release status
```

## Recovery Scenarios

### The network run stops discovering the device

1. Confirm the iPhone is unlocked, on the same LAN, and disconnected from USB.
2. Confirm the pairing record still exists:
   `ls ~/.stupid-app/credentials/pairing/remote_*.plist`.
3. If the record is gone or a fresh device was introduced, run
   `stupid-app device pair --usb` once (requires USB), answering the on-device Trust
   dialog with a generous `--timeout`, then retry.
4. Confirm the `--sudo` boundary is reachable (the sudoers grant must be scoped to the
   current binary path after a rebuild).
5. Re-run `stupid-app doctor` and fix any failures.

### The host was restored from a backup

Restoring the system restores credentials and pairing records only if they were inside
the backed-up home directory. After restore re-run `doctor` and, when missing,
re-establish credentials/signing (phase 3), pairing (phase 5), and the sudoers grant
(phase 6).

### macOS local network or USB permission prompts

Firewall/TCC prompts (local network, USB accessory access) may require a one-time user
action. They surface as actionable diagnostics rather than silent timeouts; accept the
prompts and retry.

### A residual utun interface is left behind

The native stack cleans up on success, failure, timeout, and cancellation outside the
privileged helper. If a stale interface appears, find it with
`ifconfig | grep utun`, remove it as root (`sudo ifconfig <ifname> destroy`), then
re-run `doctor`. Report any reproducible leak as a defect; manual `sudo pkill` should
never be a routine step.

## References

- `docs/engineering-handover.md` — source of truth for architecture, gates, and risks.
- `docs/macos-host-support-scope.md` — macOS mode model, work areas, and proof gates
  (including the open M4 and M5 items).
- `docs/implementation-notes.md` — chronological engineering log with verification detail.
- `docs/clean-host-setup.md` — the Linux (WSL) clean-host companion.
