# Native Signing And Device Transport Scope

## Purpose

This document scopes replacing the pinned `rcodesign` signing kernel and the
`pymobiledevice3` device stack with project-owned Swift implementations. Native signing
is now proven for the constrained shallow-app shape; native device replacement remains a
proposal.

Each existing dependency must remain the default until its corresponding native
replacement passes the same independent proof gates. Comparison must use separate copies
of an unsigned artifact; an app must still receive exactly one real signing pass. Native
signing has passed those gates and is now the only signing path. The Python device stack
remains authoritative until its independent replacement qualifies.

Implementation status (2026-08-17): the constrained shallow-app signer and independent
verifier described below are implemented and qualified. Native output passed macOS
`codesign --verify --strict`, physical-device development installation/launch, App Store
`VALID` processing and internal beta readiness, and TestFlight installation/launch.
The product bundles checksum-pinned public Apple WWDR G3 and Apple Inc. root
certificates, selects them only for a matching signing leaf, and fails loudly for an
unsupported issuer or chain rotation. The `rcodesign` runtime path and engine-selection
flags have been removed. The native device stack is not implemented.

## Summary

Both replacements are feasible, but neither is a small adapter rewrite:

- Native signing is a constrained Mach-O, CodeDirectory, resource-seal, DER, and CMS
  implementation. Limiting the first version to one thin ARM64 app executable makes the
  work bounded. The highest risks are Mach-O mutation and Apple-compatible CMS output.
- Native device support is a complete private-protocol stack: usbmux and lockdown,
  modern remote pairing, mDNS, TLS-PSK, TUN packet forwarding, RemoteXPC/RSD, AFC,
  installation proxy, and AppService launch. The highest risks are TLS-PSK
  interoperability, remote-pairing correctness, and protocol drift.
- Replacing `pymobiledevice3` removes Python 3.13, `uv`, the frozen Python environment,
  and its transitive dependencies. It does not remove `/dev/net/tun`, multicast and IPv6
  requirements, privilege separation, WSL USBIP, or the external `usbmuxd` socket.
- Replacing `usbmuxd` itself is a separate raw-USB project and remains the deferred task
  described in `docs/engineering-handover.md`.

The first decisive experiments should be a native signature parser/verifier and a
SwiftNIO SSL TLS-PSK handshake against an iPhone listener created by the proven stack.
These reduce the two largest architectural uncertainties before broad implementation.

### Relative Size

These are dependency and risk points, not calendar estimates:

| Initiative | Relative points | Qualification burden |
| --- | ---: | --- |
| Native signature parser/verifier spike | 5 | Hermetic and differential fixtures |
| Complete shallow-app native signer | 30-40 total | macOS, physical device, App Store, TestFlight |
| Native TLS-PSK interoperability spike | 5 | Privileged host and physical device |
| Native USB operations above `usbmuxd` | 15-20 | USB pairing, install, timeout, reconnect |
| Complete native CoreDevice network stack | 55-75 total | Fresh pair, tunnel, install, launch, repeated cleanup |
| Direct raw-USB replacement for `usbmuxd` | 20-30 additional | WSL USBIP packet-boundary and hotplug qualification |

The point ranges reflect implementation uncertainty, not only source volume. Device
transport has a larger ongoing maintenance cost because it depends on private protocols
that can change with iOS, while the constrained signing formats are comparatively stable.

## Current Boundaries

### Signing

`SigningPipeline` owns iOS policy and passes a narrow input to the project-owned
`NativeSigner`:

- An assembled `.app` with `embedded.mobileprovision` already present.
- The PEM private key and leaf certificate plus the matching bundled public Apple chain.
- The final, profile-authorized XML entitlements.
- The team identifier.
- Timestamping disabled for all iOS output.

Profile selection, entitlement reconciliation, and IPA construction remain outside the
signing kernel. Commands expose no signer-engine or certificate-chain paths. Release
manifests identify `native-shallow-v1` as the signer.

### Device Operations

The Python dependency currently has two adapters:

- `PyMobileDevice3Installer` performs USB discovery and installation through an external
  `usbmuxd` socket.
- `CoreDeviceRunner` owns the bundled Python helper for USB remote-pair bootstrap,
  network discovery, CoreDevice tunnel creation, installed-app verification, and launch.

The native replacement should preserve the one-shot lifecycle and explicit privileged
helper boundary. Build and signing remain unprivileged. A root-owned Swift helper should
own only TUN creation, route lifetime, tunnel sockets, and packet forwarding.

## Native Signing

### Initial Supported Shape

The first native signer should support only:

- One shallow iOS `.app` bundle.
- One thin, little-endian ARM64 `MH_EXECUTE` Mach-O.
- One Apple Development or Apple Distribution RSA identity.
- SHA-256 CodeDirectory hashes with 4 KiB code pages.
- XML and Apple DER entitlements.
- No RFC 3161 timestamp token.
- No frameworks, dylibs, app extensions, fat binaries, or other nested signable code.

The planner must fail before signing if this shape is exceeded. SwiftPM resource
`.bundle` directories may be sealed as resources when they contain no executable.
Dynamic libraries already supported by the packer must be rejected by the native engine
until leaf-first nested signing is implemented.

### Components

1. **Signing plan and bundle classifier**
   - Validate `Info.plist`, `CFBundleIdentifier`, `CFBundleExecutable`, paths, symlinks,
     executable modes, and the absence of unsupported nested code.
   - Model the plan as a signing tree even though the first accepted tree has one node.

2. **CodeResources writer**
   - Walk resources in deterministic path order.
   - Apply the required inclusion and exclusion rules.
   - Seal ordinary files with the required SHA-1 compatibility and SHA-256 hashes.
   - Seal symlink targets and eventually nested-code cdhashes and requirements.
   - Write `_CodeSignature/CodeResources` as a deterministic plist.

3. **Mach-O parser and editor**
   - Parse load commands, `__TEXT`, `__LINKEDIT`, and an existing or absent
     `LC_CODE_SIGNATURE` safely.
   - Reserve a fixed signature region, update `__LINKEDIT`, and add or replace
     `LC_CODE_SIGNATURE` without moving or overwriting section data.
   - Reject unsupported layouts, insufficient load-command space, malformed offsets,
     non-final signature data, and integer overflow.

4. **CodeDirectory and embedded-signature writer**
   - Generate code-page hashes and special-slot hashes for `Info.plist`, requirements,
     `CodeResources`, XML entitlements, and DER entitlements.
   - Encode identifier, team ID, code limits, executable-segment fields, and development
     versus distribution flags.
   - Build RequirementSet, blob indexes, offsets, padding, and the final SuperBlob.

5. **Requirements and DER entitlements**
   - Implement only the requirement opcodes needed by Apple Development and Apple
     Distribution identities.
   - Encode Apple's entitlement DER dictionary with sorted UTF-8 keys and the supported
     array, dictionary, Boolean, integer, and string values.
   - Fail loudly on unsupported plist value types.

6. **Apple-compatible CMS**
   - Produce detached RFC 5652 SignedData over the complete CodeDirectory.
   - Sign with RSA/SHA-256 PKCS#1 v1.5.
   - Include the leaf and correct Apple WWDR intermediate certificate.
   - Encode canonical signed attributes, including Apple's cdhash attributes
     `1.2.840.113635.100.9.1` and `1.2.840.113635.100.9.2`.
   - Do not contact a timestamp service or emit an RFC 3161 timestamp-token attribute.

7. **Independent native verifier**
   - Reparse the completed bundle and Mach-O.
   - Verify code pages, every special slot, CMS signature and chain, requirements,
     entitlement equivalence, resource seals, and timestamp absence.
   - Keep signer and verifier code paths sufficiently separate to reduce correlated
     implementation errors.

### Swift Dependencies

The repository already has most cryptographic building blocks:

- `swift-crypto`: SHA-1/SHA-256 and existing key primitives.
- `_CryptoExtras` or its stable successor: RSA PEM parsing and PKCS#1 v1.5 signing.
- `swift-certificates`: X.509 parsing and chain validation.
- `swift-asn1`: direct dependency for CMS and entitlement DER encoding.
- Foundation: plists and filesystem operations.

A narrow local CMS encoder is preferable to relying on unstable SPI because the public
Swift certificate APIs do not expose the required Apple custom signed attributes.
OpenSSL should not be added merely to construct CMS. A general Mach-O package may help
with parsing, but the signing-aware mutation and `__LINKEDIT` rewrite still require
project-owned code and Linux qualification.

### Signing Work Sequence

1. Freeze sanitized Xcode and `rcodesign` semantic fixtures for the supported app shape.
2. Build the read-only signature parser and verifier.
3. Implement requirement and entitlement DER golden vectors.
4. Implement deterministic `CodeResources` generation.
5. Implement and independently parse Apple-compatible CMS.
6. Implement thin ARM64 Mach-O mutation and SuperBlob insertion.
7. Add an explicit native signer engine behind the existing signing pipeline.
8. Qualify both development and distribution output.
9. Remove the external signer only after all qualification gates pass. **Complete.**

### Signing Proof Gates

- Hermetic mutation tests must detect changes to each code page, each special slot,
  every sealed resource, and each symlink target.
- Malformed and truncated Mach-O, blob, ASN.1, and plist inputs must fail without
  out-of-bounds access or partial output replacement.
- Native output must pass `codesign --verify --strict` and independent signature detail,
  entitlement, and requirement inspection on macOS.
- A development-signed IPA must install and launch on a registered physical device.
- A distribution-signed IPA must become `VALID` and `READY_FOR_BETA_TESTING`, then
  install and launch through TestFlight.
- The exact development and distribution artifacts must be signed only by the native
  engine during their respective proof runs.

### Signing Risks And Licensing

The main correctness risk is a signer and verifier that share the same format mistake.
Differential inspection and Apple acceptance remain mandatory. WWDR intermediate
rotation must be handled as certificate-chain policy rather than hard-coded forever.

`apple-codesign` is MPL-2.0. A close Rust-to-Swift translation is likely derived work
and should retain MPL notices and source-availability obligations at the translated-file
level. A clean-room implementation from format specifications and independently captured
fixtures has different provenance, but requires disciplined separation and legal review.
Do not copy Apple XNU or GPL implementation source merely to reproduce constants or
wire layouts.

## Native Device Stack

### Retained Platform Dependencies

The first native device implementation should continue to connect to the external
`usbmuxd` Unix socket. The following remain external requirements:

- USB kernel support and WSL USBIP for the bootstrap connection.
- The qualified short-packet `usbmuxd` behavior on WSL USBIP.
- `/dev/net/tun`, Linux IPv6/TUN support, and `CAP_NET_ADMIN` or a root-owned helper.
- UDP multicast port 5353, LAN mDNS reachability, IPv6 scope handling, and host firewall
  configuration.
- A trusted, unlocked iPhone with Developer Mode and required device services available.
- Pairing records treated as owner-only credentials.

Direct ownership of the Apple USB interface, usbmux v2 multiplexing, hotplug, and
short-packet behavior is independent follow-up scope.

### Protocol Components

1. **usbmux client**
   - Implement plist-framed `ListDevices`, `ReadBUID`, `ReadPairRecord`,
     `SavePairRecord`, and `Connect` over Unix or TCP sockets.
   - Preserve request tags, partial-read handling, port byte order, timeouts, and
     reconnect behavior.

2. **Lockdown client and pairing**
   - Implement length-prefixed plist requests for pairing, session validation, values,
     and service startup.
   - Generate the RSA root, host, and device certificate chain used by lockdown pairing.
   - Enable and verify `com.apple.mobile.wireless_lockdown/EnableWifiConnections`.

3. **USB CoreDeviceProxy bootstrap**
   - Start `com.apple.internal.devicecompute.CoreDeviceProxy` through lockdown.
   - Exchange the `CDTunnel` JSON handshake.
   - Establish temporary TUN forwarding to Remote Service Discovery.

4. **CoreDevice remote pairing**
   - Implement `RPPairing` framing and protocol version 19 envelopes.
   - Implement TLV8 fragmentation and reassembly.
   - Implement SRP-3072/SHA-512 pair setup, X25519 pair verify, Ed25519 signatures,
     HKDF-SHA512 key schedules, ChaCha20-Poly1305 envelopes, and sequence nonces.
   - Implement the narrow OPACK subset used by pairing metadata.
   - Persist remote records atomically with mode `0600`.
   - Investigate and correctly validate the device peer signature rather than silently
     preserving the missing verification in the inspected Python implementation.

5. **mDNS discovery**
   - Browse `_remotepairing._tcp.local.` on IPv4 and IPv6 multicast.
   - Decode compressed PTR, SRV, TXT, A, and AAAA records.
   - Handle link-local interface scopes, duplicate advertisements, address preference,
     and candidate deduplication.
   - Trust the selected device only after RSD returns the requested UDID.

6. **TLS-PSK TCP tunnel and TUN forwarding**
   - Create the encrypted remote listener, connect with TLS 1.2 PSK, and exchange the
     `CDTunnel` handshake.
   - Configure a nonpersistent Linux TUN interface and route.
   - Frame complete IPv6 packets in both directions and tear down on EOF, failure,
     timeout, or cancellation.

7. **RemoteXPC and RSD**
   - Implement the required HTTP/2 preface, settings, stream, data, and flow-control
     behavior.
   - Implement the Apple binary XPC wrapper and supported scalar, collection, UUID,
     data, and file-transfer values.
   - Resolve the peer UDID and required service ports.

8. **AFC and installation proxy**
   - Perform RSD service check-in for the AFC and installation-proxy shims.
   - Stream the IPA to `/PublicStaging` with AFC framing.
   - Install as a developer package, decode bounded progress and terminal errors, and
     remove the staged IPA on every exit path.
   - Verify the exact bundle ID and preferably its version/build through `Lookup`.

9. **AppService launch**
   - Invoke `com.apple.coredevice.appservice` over RemoteXPC with the required launch
     feature and options.
   - Require a process identifier in the response and surface private-protocol version
     incompatibility as an actionable error.

### Swift Dependencies

A practical implementation would use:

- Swift concurrency and actors for lexical lifecycle ownership.
- SwiftNIO for Unix/TCP sockets and event-loop integration.
- SwiftNIO SSL/BoringSSL for portable TLS 1.2 PSK.
- Existing `swift-crypto` for X25519, Ed25519, HKDF, ChaChaPoly, and hashes.
- Existing RSA/X.509 support for lockdown pairing certificates.
- A pinned BigInt implementation plus a narrow, vector-tested SRP implementation.
- Foundation for plist and JSON data.
- A small Linux system-library target for TUN and interface operations.
- Project-owned narrow codecs for DNS-SD, OPACK, binary XPC, AFC, and any HTTP/2 behavior
  that a standards-enforcing library cannot represent exactly.

Do not mechanically translate GPL `pymobiledevice3` source into Swift if avoiding that
license is an objective. Use protocol captures, independently written fixtures, public
references, and clean-room implementation practices. Record provenance for every
adapted algorithm and format.

### Device Work Sequence

1. Capture sanitized, bounded protocol fixtures from the proven pinned environment.
2. Prove SwiftNIO SSL can complete the device's TLS-PSK handshake and record the
   negotiated cipher and accepted PSK identity behavior.
3. Implement native usbmux, lockdown, USB discovery, pairing validation, AFC, and
   installation proxy while retaining external `usbmuxd`.
4. Implement binary XPC, RemoteXPC, and RSD read-only service discovery.
5. Implement the privileged TUN helper and deterministic packet-pump cleanup.
6. Connect through an existing remote pairing record and create a native network tunnel.
7. Implement fresh SRP remote-pair setup and USB bootstrap record creation.
8. Implement native installation verification and AppService launch.
9. Cut CLI options and doctor checks over to an explicit native backend.
10. Remove Python tooling only after clean-host and physical-device qualification.

This ordering delivers useful Python removal for USB discovery and installation before
the harder network pairing work is complete. It also tests TLS-PSK early enough to stop
or revise the architecture cheaply.

### Device Proof Gates

- Hermetic fixtures must cover fragmented and coalesced frames, partial writes, malformed
  lengths, TLV8 boundaries, cryptographic intermediate values, DNS compression loops,
  HTTP/2 flow control, XPC alignment, AFC sequence numbers, install failures, and cleanup.
- Privileged tests must prove TUN and route removal after success, timeout, cancellation,
  controller death, and either packet-pump direction failing.
- USB qualification must cover discovery, lockdown validation, fresh pairing, wireless
  enablement, CoreDeviceProxy startup, install, disconnect/reconnect, and cancellation.
- Network qualification must start physically unplugged, discover the selected device,
  verify its RSD UDID, install and verify the exact app, launch it, and return a PID.
- Three consecutive unplugged runs must leave no helper process, TUN interface, route,
  staged IPA, or USB dependency.
- Qualification must run on a clean supported Linux/WSL host and repeat for each declared
  supported iOS protocol family.

### Device Risks

- SwiftNIO SSL exposes PSK APIs, but compatibility with the iPhone listener's cipher and
  empty-identity behavior is not yet proven.
- SRP and remote-pair state mistakes can create subtle security or interoperability
  defects; do not implement unaudited arbitrary-precision crypto from scratch.
- CoreDevice service names, wire version 19, AppService version fields, request keys,
  and response shapes are private and can drift with iOS.
- RemoteXPC uses unusual HTTP/2 framing that a strict high-level library may reject.
- Native code above `usbmuxd` does not fix WSL USBIP transfer-boundary failures.
- A privileged helper handles tunnel keys and briefly needs access to the IPA and pairing
  record. Its request surface and filesystem access must remain narrow.

## Recommended Delivery Plan

Treat these as two independent initiatives rather than one cutover.

1. **Native signing verifier spike**
   - Parse and validate existing Xcode and `rcodesign` output before writing signatures.
2. **Native TLS-PSK spike**
   - Connect SwiftNIO SSL to a listener created by the proven device stack.
3. **Native USB operations**
   - Remove Python from USB discovery and install while retaining `usbmuxd` and the
     proven CoreDevice helper for launch.
4. **Native shallow-app signing**
   - Add an explicitly selected native engine and complete development/App Store proof.
5. **Native CoreDevice network stack**
   - Complete remote pairing, tunnel, RSD, install, and launch with the privileged Swift
     helper.
6. **Dependency retirement**
   - Native signing has retired `rcodesign` independently. Remove Python, `uv`, and
     `pymobiledevice3` only after the native device path passes clean-host acceptance.
     Keep no silent compatibility fallback.

The signing initiative is bounded enough to complete independently. The device initiative
should be expected to require ongoing compatibility maintenance as new iOS releases alter
private CoreDevice protocols.
