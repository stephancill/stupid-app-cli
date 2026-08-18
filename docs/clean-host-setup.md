# Clean Host Setup And Recovery

This document describes how to bring a fresh Linux (WSL 2 Ubuntu) host to the point
where the full `stupid-app` workflow runs, and how to recover a host that has drifted.
It is the operational companion to `docs/engineering-handover.md`; treat that document
as the source of truth and update both together.

The goal of a "clean host" is a machine whose runtime state is produced entirely by
repeatable commands in this document plus the one-time credentials the operator supplies,
so a broken environment can be rebuilt without guessing at hidden state.

## Prerequisites

- A fresh x86_64 Ubuntu 24.04 WSL 2 distribution (the validated pair is Swift 6.2.4,
  Xcode 26.1.1 / iPhoneOS SDK 26.1, host `x86_64-unknown-linux-gnu`).
- The `stupid-app` source tree on the host.
- One exported iOS Swift SDK bundle (see `docs/sdk-export-format.md`).
- App Store Connect team API key, issuer ID, `.p8`, and team ID.
- A physical iPhone with Developer Mode enabled, on the same LAN, unlocked for pairing.

## Initial Setup Order

Each phase has a verification command that must pass before the next phase.

### 1. System packages

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential clang cmake ninja-build git curl \
  libssl-dev libicu-dev libxml2-dev libsqlite3-dev \
  libzstd-dev python3 zip unzip
```

Verification: `swift --version` reports Swift 6.2.4 with target
`x86_64-unknown-linux-gnu`.

### 2. Import the iOS Swift SDK

```bash
swift build
.build/debug/stupid-app sdk import \
  stupid-app-ios-arm64-apple-ios-x86_64-unknown-linux-gnu.artifactbundle.tar.zst \
  --expected-sha256 <sha256>
swift sdk list
```

Verification: `swift sdk list` shows the artifact ID (currently `ios-dev` for the
proof bundle; re-exported bundles register as `stupid-app-ios`). The CLI commands below
use `--sdk-id ios-dev` until the bundle is re-exported under the new name.

### 3. Credentials and signing identities

```bash
stupid-app credentials add
stupid-app signing setup --kind distribution --bundle-id <bundle-id>
stupid-app signing setup --kind development --bundle-id <bundle-id> --udid <udid> --device-name "<name>"
```

Verification: `stupid-app doctor --sdk-id ios-dev` reports 0 failures. The credential
directory is `~/.stupid-app/credentials`, mode `0700`, secret files mode `0600`.

### 4. Pairing records

`stupid-app device pair --usb` requires a USB-attached iPhone and the qualified
USBIP-compatible usbmuxd for large transfers. A host that already has an owner-only
`remote_<id>.plist` record in `~/.stupid-app/credentials/pairing` can skip straight to
network runs.

Verification: `stupid-app doctor --sdk-id ios-dev` reports the pairing records check as
`PASS`.

### 5. Privilege boundary for TUN

CoreDevice network tunneling creates a TUN interface and needs `CAP_NET_ADMIN`. The CLI
never elevates implicitly. Two supported arrangements:

- **Setcap on the binary (proof-host arrangement):** the whole network run stays
  unprivileged and the binary is granted the capability.
  ```bash
  sudo setcap cap_net_admin=ep .build/debug/stupid-app
  ```
  Every rebuild wipes the capability; re-apply after `swift build`/`swift test`.
- **Scoped sudo grant (product arrangement):** install the binary root-owned and grant
  only the helper subcommand in sudoers.
  ```bash
  sudo install -o root -g root -m 755 .build/release/stupid-app /usr/local/bin/stupid-app
  echo 'iosdev ALL=(root) NOPASSWD: SETENV: /usr/local/bin/stupid-app coredevice-helper *' \
    | sudo tee /etc/sudoers.d/stupid-app-coredevice
  sudo chmod 440 /etc/sudoers.d/stupid-app-coredevice
  sudo visudo -c
  ```
  The CLI then runs with `--sudo /usr/bin/sudo`. Do not grant broad `NOPASSWD: ALL`.

Verification: `stupid-app doctor --sdk-id ios-dev` reports the tunnel device check as
`PASS`, and `stupid-app run --network ...` completes.

### 6. Health check

```bash
stupid-app doctor --sdk-id ios-dev
```

A clean host exits 0. `[WARNING] Project configuration` is expected when run outside a
project directory.

## Daily Use

```bash
stupid-app run --network --udid <udid> --sdk-id ios-dev --sudo /usr/bin/sudo
stupid-app release archive --sdk-id ios-dev
stupid-app release upload --wait --sdk-id ios-dev
stupid-app release status
```

## Recovery Scenarios

### The network run stops discovering the device

1. Confirm the iPhone is unlocked, on the same LAN, and disconnected from USB.
2. Re-apply the capability if the binary was rebuilt: `sudo setcap cap_net_admin=ep .build/debug/stupid-app`.
3. Confirm the pairing record still exists:
   `ls ~/.stupid-app/credentials/pairing/remote_*.plist`.
4. If the record is gone or a fresh device was introduced, run
   `stupid-app device pair --usb` once (requires USB) then retry.
5. Re-run `stupid-app doctor --sdk-id ios-dev` and fix any failures.

### The host was re-imported or restored from an image

Restoring a WSL image restores credentials and pairing records only if they were inside
the image. The reusable base image deliberately contains no credentials or SDK bundle,
so after restore:

1. Re-import the SDK bundle (phase 2).
2. Re-run `credentials add` and `signing setup` (phase 3) or restore the credential
   directory from a secure owner-only backup.
3. Re-pair the device (phase 4) or restore the pairing directory.
4. Re-apply the privilege boundary (phase 5).
5. Run `doctor` (phase 6).

Treat WSL exports, virtual disks, and backups as secret-bearing once credentials are
present, and store them with equivalent protection to the credential directory.

### The WSL VM keeps stopping between commands

Keep the VM alive with `vmIdleTimeout=-1` in the Windows `.wslconfig`. A stopped VM
invalidates the non-persistent USBIP attach and kills `usbmuxd`, which appears as
mux/lockdownd failures on USB paths.

### A residual process or TUN interface is left behind

The native stack cleans up on success, failure, timeout, and cancellation. If a stale
interface appears, find it with `ip -o link show type tun` and remove it as root
(`sudo ip link delete <ifname>`), then re-run `doctor`. Report any reproducible leak as
a defect; manual `pkill` should never be a routine step.

## References

- `docs/engineering-handover.md` — source of truth for architecture, gates, and risks.
- `docs/implementation-notes.md` — chronological engineering log with verification detail.
- `docs/sdk-export-format.md` — SDK bundle format and import requirements.
- `docs/native-dependency-replacement-scope.md` — native device/signing scope history.
