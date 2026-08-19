# Project Agent Instructions

## Mandatory Context

Before planning, editing code, changing configuration, running a release workflow, or making architectural recommendations:

1. Read this file completely.
2. Read `docs/engineering-handover.md` completely.
3. Read `docs/implementation-notes.md`, focusing on the latest entries and any entries related to the task.
4. Inspect the current repository state, configured toolchain, and relevant tests rather than assuming the handover is perfectly current.

If code and documentation disagree, investigate the discrepancy. Do not silently choose one. Correct the handover as part of the same work when current implementation has legitimately superseded it.

## Documentation Responsibilities

`docs/engineering-handover.md` is the current source of truth. Update it when work changes:

- Scope or acceptance criteria.
- Architecture or component boundaries.
- Command names or behavior.
- Supported hosts, SDKs, Swift versions, iOS versions, resources, or project shapes.
- Authentication, credential storage, signing, provisioning, or upload behavior.
- Risks, limitations, open decisions, or recommended next work.
- Technical proof-gate status.

`docs/implementation-notes.md` is the chronological public engineering log. Append a dated entry after meaningful work describing changes, reasoning, decisions, verification, failures, and follow-ups.

`README.md` and the bundled CLI skill (`skills/stupid-app-cli/`) document the
user-facing command surface. Whenever a command, option, default, output path,
or behavior the skill or README describes changes, update both in the same work.
Do not commit a CLI surface change with the README or `references/commands.md`
out of date; run the skill-creator validation after skill edits.

Before committing changes, inspect both documents and update them where necessary. Never defer a required documentation update merely because the code is complete.

Implementation notes must be safe for public publication. Never record personal information, credentials, tokens, private keys, certificate contents, account identifiers, device identifiers, private hostnames, or secret-bearing output.

Do not include timeline estimates in planning documents. Use ordered dependencies and acceptance gates. If relative estimation is genuinely useful, use points rather than days or weeks.

## Product Invariants

- Normal project creation, build, signing, wireless deployment, and release must not require Xcode or macOS at runtime.
- A one-time Mac-side SDK export from the user's own Xcode installation is an accepted prerequisite.
- Do not distribute Apple SDK files or derived SDK bundles.
- Version 1 supports CLI-owned SwiftPM/SwiftUI physical-device applications, not arbitrary Xcode projects.
- Keep unsupported resource and project types explicit. Fail loudly instead of silently copying or degrading them.
- Paid Apple Developer Program membership is required.
- Use App Store Connect team API keys and public Apple APIs.
- Do not implement Apple ID password, anisette, GrandSlam, or private Apple authentication as a fallback.
- Preserve configured bundle identifiers exactly. Do not introduce an `XTL-*` or similar prefix.
- Device builds use a real Apple Development certificate and profile.
- Release builds use a real Apple Distribution certificate and iOS App Store profile.
- Never pseudo-sign or ad-hoc sign an app as an intermediate build, provisioning, installation, or release step.
- Requested entitlements come from source configuration and are reconciled with the selected profile before the single real signing pass.
- Successful App Store Connect processing and TestFlight installation are the authority for release-signing compatibility.
- A distribution-signed IPA and release manifest are required outputs. Do not require `.xcarchive` unless a future concrete consumer needs it.
- Prefer failing loudly over fallback behavior.
- Do not add backward-compatibility behavior without an existing persisted format, shipped behavior, external consumer, or explicit requirement.

## Current Technical Direction

- Implement the primary CLI in Swift unless a proof gate establishes a better concrete architecture.
- Adapt the separable planner and packer ideas from xtool's `Sources/PackLib`; do not copy the monolithic development command.
- Keep SDK handling, build planning, packaging, Apple APIs, signing, device transport, and release upload as independent modules.
- Use a versioned, checksummed, device-only Swift SDK export and atomic Linux import.
- Validate exact Swift compiler, Xcode SDK, host triple, and Darwin-tool compatibility.
- Evaluate a pinned `apple-codesign`/`rcodesign` revision as the signing kernel.
- Do not add Zupersign as a fallback.
- Disable signing timestamps for iOS distribution output.
- Use the App Store Connect Build Upload APIs instead of `altool` or Transporter.
- Use a pinned `pymobiledevice3` integration for the first modern wireless transport proof, while keeping the transport replaceable.
- Treat pairing records and signing material as credentials.

## Security Rules

- Never commit `.env.local`, App Store Connect `.p8` keys, signing private keys, PKCS#12 files, provisioning profiles containing operational identifiers, pairing records, or release directories containing private material.
- Use private directories with mode `0700` and secret files with mode `0600`.
- During technical validation, store credentials as owner-only plaintext files in a
  mode `0700` directory with mode `0600` files. Do not add a credential passphrase or
  legacy environment fallback without an explicit security-design change.
- Use atomic writes for credentials and active SDK installations.
- Redact secrets and personal identifiers from logs, errors, tests, snapshots, and implementation notes.
- Do not print raw API authorization headers or JWTs.
- Treat VPS images, snapshots, caches, and backups as secret-bearing when they include credentials.
- Validate downloaded tools and SDK import archives with pinned checksums.
- Reject archive path traversal, absolute paths, and symlinks that escape the installation root.

## Engineering Style

- Make the smallest correct change.
- Prefer explicit data flow over hidden global state.
- Prefer named parameters and typed configuration.
- Keep one function until a boundary is reusable or materially improves testability.
- Avoid speculative compatibility layers and fallback implementations.
- Add comments only where the code's reason or invariant is not self-evident.
- Keep user-facing errors actionable and include the failing phase, expected condition, and safe recovery step.
- Separate secret-bearing diagnostic detail from public-safe summaries.
- Keep build, sign, install, launch, upload, and poll operations independently testable.

## Swift Conventions

- Use the repository's pinned Swift toolchain and package manager configuration.
- Format Swift with the repository's configured formatter. If none is configured, establish `swift format` before substantial implementation.
- Run the repository's configured linting after Swift changes when available.
- Use Swift concurrency deliberately and avoid detached background processes that survive command cancellation.
- Prefer value types and protocol boundaries over class hierarchies unless shared identity or actor isolation requires otherwise.
- Do not hide process failures. Capture exit status, bounded output, cancellation, and timeout behavior explicitly.

## Testing And Verification

- Every bug fix should include a regression test when the behavior can be reproduced deterministically.
- Unit-test parsing, validation, planning, and state transitions without Apple credentials.
- Use sanitized fixtures for certificates, profiles, signatures, and App Store Connect responses.
- Keep credentialed and physical-device tests clearly separated from ordinary unit tests.
- Record exact verification commands and outcomes in implementation notes.
- Do not claim success for signing based only on local ZIP structure or upload transport completion.
- Do not claim wireless support from a USB-attached run.
- Do not claim Linux compatibility based only on a macOS build.
- Run proof gates on clean supported hosts, not only a developer machine with undeclared state.

## External References

The engineering handover lists the currently relevant xtool, App Store release, App Store Connect, `apple-codesign`, and `pymobiledevice3` references. Consult those sources when changing corresponding behavior, but verify current source and API schemas because external implementations evolve.

When copying or adapting source, preserve license requirements and record provenance in the implementation notes and repository notices.
