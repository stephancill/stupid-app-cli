# rcodesign Signing Kernel Pin

This document records the pinned revision and provenance for the `rcodesign` signing
kernel used by the distribution signing pipeline. Treat this document as the source of
truth for the pin until it is updated.

## Decision

Use upstream **prebuilt release binaries** rather than compiling `rcodesign` on every
supported host. Apple ships no Linux signing tooling, so a low-level signing kernel is
required for Mach-O signing, CMS, nested-bundle resource sealing, and XML/DER
entitlements on non-macOS hosts. Many candidates were considered:

- Writing a signing engine in this repository is out of scope and high risk.
- Zupersign (used by the reference xtool adapter) is excluded for entitlement and
  robustness reasons and is unmaintained relative to `apple-platform-rs`.
- `apple-codesign` / `rcodesign` provides the strongest cross-platform Mach-O and
  bundle signing implementation available and is maintained upstream.

Building `rcodesign` from source on every target host would require a Rust toolchain and
a per-architecture compile, which contradicts the goal of minimizing target-host
dependencies across multiple architectures. Upstream publishes statically linked `musl`
binaries per architecture for every release, so a prebuilt binary can be pinned by
release tag and SHA-256 without adding a Rust toolchain to any supported host.

The pinned source checkout remains in the ignored `third-party/apple-platform-rs`
directory for auditability and to reproduce binaries when required, but it is not a
target-host compile requirement.

## Pin

- Upstream repository: `https://github.com/indygreg/apple-platform-rs`
- Crate: `apple-codesign`
- Crate version: `0.29.0`
- Pinned source revision: `2312b1e5bd77322c019613e0ca624e222c6c6e08`
  - Tag: `apple-codesign/0.29.0`
  - Tag object: `5b004030fc722c2e2064d65d257385c86ab471b8`
- License: MPL-2.0 (confirmed in `apple-codesign/Cargo.toml` and `apple-codesign/LICENSE`).
  Obligations: file-level copyleft under the Mozilla Public License 2.0; modifications to
  MPL-licensed files must be made available in source form when distributed. No binary is
  distributed by this repository in releases; hosts download the pinned binary from the
  upstream release.

## Prebuilt Binaries

Per-architecture upstream release assets for `apple-codesign/0.29.0`:

| Target triple | Archive SHA-256 | rcodesign binary SHA-256 |
| --- | --- | --- |
| `x86_64-unknown-linux-musl` | `dbe85cedd8ee4217b64e9a0e4c2aef92ab8bcaaa41f20bde99781ff02e600002` | `dab9a7465f96aba3c81e793775510f745b91a46b6418e89f7317b5d8fc7bcea2` |
| `aarch64-unknown-linux-musl` | `4af92c87ddf52f5f2d1258a3b4e56c7dcb8f1b2468df744976c5f139e031961f` | `79e9d9a5e36df464f42d23da5ccb97f041b0ad3207e57c9dc0053198193441f5` |
| `aarch64-apple-darwin` | `d1a532150adaf90048260d76359261aa716abafc45c53c5dc18845029184334a` | (see macOS notes below) |

Download URLs use the upstream release layout:

```text
https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/0.29.0/apple-codesign-0.29.0-<triple>.tar.gz
```

The `x86_64-unknown-linux-musl` binary verified as a static-pie ELF; the
`aarch64-unknown-linux-musl` binary verified as a statically linked ELF. No runtime
library requirements on the target host beyond the pinned archive's `rcodesign` and
`COPYING` files.

## macOS Local Build (Reproduction Only)

This Mac is not a supported target host, but a local source build was performed to
confirm the pinned source builds cleanly and supports local comparison signing on
macOS, where `codesign --verify --strict` can validate the signer output independently.

- Rust toolchain used: `cargo` / `rustc` 1.94.1.
- Build command: `cargo build --release -p apple-codesign --bin rcodesign`
- Output: `third-party/apple-platform-rs/target/release/rcodesign`
- Reported version: `apple-codesign 0.29.0`
- Binary SHA-256: `fafaf41593c309601bad6cd2b07190bf2607b3024de2291930150f253c03b4be`
- Build notes: completed with warnings only (elided lifetime warnings and a
  `num-bigint-dig` future-incompatibility notice). Enabling a Linux target on macOS
  fails because no `x86_64-linux-gnu-gcc` cross toolchain is installed; cross-compiling
  on macOS is not required given prebuilt Linux binaries.

## CLI Integration Rules

- `rcodesign` may be located on PATH, discovered from an injected configuration, or
  resolved from a per-host downloaded binary cache. On supported hosts it must be the
  pinned binary (verified by SHA-256) or a rebuilt binary from the pinned source.
- `stupid-app` must fail loudly if the configured signer is unavailable or its output
  fails verification. A silent fallback to another signer is not allowed.
- iOS distribution signing must disable timestamps. Pin the validated binary/revision
  before production proof work.