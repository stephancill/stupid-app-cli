# Gate M4 Plan: macOS-Hosted Darwin Tools (Mode B)

Gate M4 makes the Xcode-absent macOS path (Mode B) work: a Mac with no Xcode must build
against an imported device-only SDK bundle using a macOS-hosted Mach-O linker,
`libtool`, and `dsymutil`. This document is the scouting result and plan for that gate.
It updates design decision 5 in `docs/macos-host-support-scope.md` in light of a concrete
finding.

## Finding: Homebrew publishes all three tools, and they link iOS Mach-O

The original decision (5) assumed "no upstream publishes these binaries", so the plan was
to **build LLVM from source**. Scouting on this Mac found that Homebrew already packages
the exact tools as prebuilt, open-source binaries:

| Tool (bundle name) | Binary | Origin | Version (this Mac) |
| --- | --- | --- | --- |
| `ld64.lld` | `lld` (symlink `ld64.lld`) | Homebrew `lld` formula | LLD 20.1.8 |
| `libtool` | `llvm-libtool-darwin` | Homebrew `llvm` formula | LLVM 20.1.8 |
| `dsymutil` | `dsymutil` | Homebrew `llvm` formula | LLVM 20.1.8 |

All are built from the open-source LLVM project (`lld` + `llvm/tools`), Apache-2.0 with
LLVM exceptions, so they satisfy the licensing requirement of decision 5.

**Functional smoke test (this Mac, 2026-08-18):** the Homebrew `ld64.lld` accepted
`-arch arm64 -platform_version ios 17.0 26.1`, linked a minimal object, and produced a
valid `EXECUTE` ARM64 Mach-O whose `LC_BUILD_VERSION` reports `platform IOS minos 17.0` —
the exact linker metadata Mode B needs. `dsymutil` ran and `llvm-libtool-darwin -static`
produced a working archive.

## Recommended approach: pin and bundle Homebrew/LLVM prebuilt binaries (relocate)

Rather than building LLVM from source, package the three prebuilt binaries plus their
runtime dylibs into the SDK bundle's `toolset/bin` and `toolset/lib`, then make them
relocatable. The from-source LLVM build remains the fallback (see Risks).

### Dependency set to bundle

The binaries are not static; they depend on LLVM dylibs:

- `ld64.lld` (`lld`) depends on `@rpath/liblld{MachO,Common,ELF,COFF,Wasm,MinGW}.dylib`
  (already resolved via the `@loader_path/../lib` rpath the Homebrew build carries) and on
  the **absolute** path `/opt/homebrew/opt/llvm@20/lib/libLLVM.dylib`.
- `dsymutil` and `llvm-libtool-darwin` depend on `@rpath/libLLVM.dylib`.

Relocation procedure (to validate during implementation):

1. Copy `lld` → `toolset/bin/ld64.lld`, `llvm-libtool-darwin` → `toolset/bin/libtool`,
   `dsymutil` → `toolset/bin/dsymutil`.
2. Copy `liblld{MachO,Common,ELF,COFF,Wasm,MinGW}.dylib` and `libLLVM.dylib` →
   `toolset/lib`.
3. `install_name_tool -change /opt/homebrew/opt/llvm@20/lib/libLLVM.dylib @rpath/libLLVM.dylib`
   on each of the three binaries (the lld dylibs already use `@rpath`, and the binaries
   already carry an `@loader_path/../lib` rpath).
4. Verify with `otool -L` that no path outside the bundle remains (only `@rpath` and
   system `/usr/lib` / framework paths).

Footprint: `libLLVM.dylib` is ~138 MB and the six `liblld*.dylib` are small; the bundled
toolset is ~140-150 MB. That is a notable but acceptable size for a developer-side tool
bundle and is imposed by bundling LLVM's shared library.

## Exporter changes (Mode B bundle)

`DarwinTools` (`Sources/SDKCore/DarwinTools.swift`) currently pins only the Linux
`x86_64` archive. It gains a macOS-hosted source set selected by `*-apple-macosx` host
triples:

- Extend `DarwinTools.Source` to describe the macOS tools by **installed Homebrew
  paths** plus per-file SHA-256 (and the pinned LLVM/lld revision and Homebrew formula
  revision) rather than a single upstream archive, since the exporter may run on the
  Mac being prepared. `sdk export --host <arm64-apple-macosx>` then stages the tools from
  Homebrew (or from a locally fetched, checksummed copy), relocates them via
  `install_name_tool`, and embeds them under `toolset/bin` and `toolset/lib`.
- The existing `toolset.json` schema already names `linker.path = ld64.lld`, `rootPath =
  toolset/bin`, and `-use-ld=lld`; the macOS bundle reuses it unchanged, with
  `llvm-libtool-darwin` installed as `libtool`.
- The `sdk-manifest.json` `darwinTools` field records the macOS source/version/checksum
  and per-file SHA-256, mirroring the Linux record.
- The `DarwinTools.binaries` list (`["ld64.lld", "libtool", "dsymutil"]`) is unchanged;
  unsupported macOS host archs (x86_64) fail loudly under decision 8.

## Validation steps (implementation phase)

1. **Relocation proof:** after `install_name_tool`, `otool -L` shows only `@rpath` and
   system paths; the three binaries run from a copied bundle location (move the bundle
   elsewhere and execute each binary).
2. **Toolset-in-place link:** using only the bundled binaries (not Xcode's), link a
   minimal arm64 object with `-arch arm64 -platform_version ios 17.0 26.1` and verify the
   resulting Mach-O `LC_BUILD_VERSION` (repeat the smoke test above through the bundled
   copy).
3. **Mode B build via bundle:** with a swiftly-installed swift.org host Swift and the
   imported bundle, `stupid-app build` reproduces the M0 artifact; `doctor` reports Mode B
   active and passes. (Requires the swift.org toolchain; the current Mac's `swift` is
   Xcode's, so this needs a swiftly install or a clean no-Xcode Mac.)
4. **`-use-ld=lld` discovery:** confirm the swift.org driver locates `ld64.lld` from the
   bundle `toolset.json` `rootPath`/`linker.path` (the one remaining discovery unknown;
   see Risks).
5. **Full M4 gate:** `release archive` + `release upload --wait` process to
   `VALID`/TestFlight readiness, and the M3 device run repeats, on a clean Mac with no
   Xcode.

## Order of work

1. Extend `DarwinTools` with the macOS-hosted source set and make `sdk export --host
   <arm64-apple-macosx>` stage, relocate, checksum, and embed the tools.
2. Validate relocation (validation 1) and the toolset-in-place link (validation 2) on
   this Mac using the existing Homebrew install.
3. Resolve `-use-ld=lld` discovery against a swiftly-installed swift.org toolchain
   (validation 3-4); document CLT as a Mode B prerequisite only if empirically required
   (decision 6).
4. Clean-host Mode B acceptance (the M4 exit condition).

## Risks And Decisions

- **Relocation correctness** is the primary risk. If `install_name_tool` relocation of
  `libLLVM.dylib` proves fragile across macOS versions, fall back to building
  self-contained static `ld64.lld`/`dsymutil`/`llvm-libtool-darwin` from the pinned LLVM
  source (the original decision-5 approach), accepting a much longer build.
- **`-use-ld=lld` discovery by the swift.org driver** is unvalidated. If the driver does
  not honor the toolset `linker.path` on Darwin, Mode B may need `-Xlinker`/environment
  wiring or a scoped `ld` wrapper; fail loudly and document rather than silently fall
  back to Xcode's linker.
- **Pinning:** record the Homebrew formula revision and the exact LLVM 20.1.8 source
  revision plus per-binary/dylib SHA-256. Bottles change; do not ship un-pinned bytes.
- **Relative size:** the ~140-150 MB toolset is accepted for a Mode B developer bundle.
- **swift.org toolchain:** Mode B requires a swiftly-installed toolchain on the Mode B Mac
  with no Xcode; CLT is accepted only if empirically required (decision 6).
- **Intel deferred:** `x86_64-apple-macosx` bundles and hosts remain out of scope
  (decision 8).
