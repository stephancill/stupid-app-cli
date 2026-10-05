# Userspace Wireless Tunnel Spike

## Objective

Qualify repeated wireless installs through a process-local IPv6/TCP stack on macOS
and Linux. Existing saved remote pairings are prerequisites; fresh USB pairing
and USB launch remain outside this spike.

Promoted in 0.0.20: `stupid-app run --network` and the GUI's wireless Run now use
this process-local transport on macOS and Linux. The separate developer proof
executable remains available for transfer/repeat qualification.

## Implementation

1. Existing native mDNS discovery and Pair-Verify establish the TLS-PSK endpoint.
2. The existing CoreDevice TLS connection exchanges the CDTunnel handshake.
3. A packet-only variant of the existing TLS relay exchanges bare IPv6 packets over
   a local datagram socketpair.
4. lwIP 2.2.1 handles IPv6/TCP on one joined worker thread. A narrow C API exposes
   create, connect, stop, and destroy. An owned local stream socket is returned for
   each successful TCP connection.
5. An injected RSD socket factory reaches the tunnel server and advertised service
   ports. Existing RemoteXPC, AFC, installation proxy, and AppService code operate
   on those streams. The RSD control connection stays alive during service work.

The pinned upstream commit is `77dcd25a72509eb83f72b033d219b1d40cd8eb95`
(`STABLE-2_2_1_RELEASE`). Upstream files remain unmodified; license/provenance live
in `THIRD_PARTY_NOTICES.md` and the vendored `COPYING`.

## Running The Spike

```sh
swift build --product userspace-tunnel-spike
.build/debug/userspace-tunnel-spike --timeout 60 --repeat 3
.build/debug/userspace-tunnel-spike \
  --pairing-dir <private-pairing-directory> --udid <device-udid> \
  --ipa <development-signed-ipa> --bundle-id <bundle-identifier> \
  --transfer-mib 12 --timeout 240 --repeat 3
swift test --filter 'UserspaceIPTests|CoreDeviceTLSRelayTests'
```

Without an IPA the executable verifies RSD identity and a concurrent AFC service
connection. `--transfer-mib` adds a temporary file upload, download, exact byte
comparison, and removal; accepted sizes are 0 through 32 MiB. With an IPA it also
installs, verifies the exact bundle, removes the staged package, and launches.
The default pairing directory is the ordinary credential store. Omitting `--udid`
is permitted only when exactly one mapped device exists. Root execution is
rejected. Run this developer proof as the ordinary deployment account.

For an explicitly authorized copied pairing, supply
`--pairing-host-id <original-host-uuid>`. Pair-Verify signs the original host
identity, not the new host's hostname-derived identity. The legacy credential format stores keys but
omits that identity, so copying its keys alone fails verification on a different
host. This override is explicit, applies only to the selected pairing attempt,
and does not rewrite credentials. Persisting the identity alongside its key is
part of the eventual credential design; production CLI defaults are unchanged.

`--timeout` bounds socket operations and the TLS relay lifetime; it is not an
overall wall-clock deadline for discovery plus every candidate attempt. Repeat
counts are bounded from 1 through 10. Cancellation/worker cleanup is exercised
in deterministic tests; remote temporary-file cleanup is best-effort on failure.

## Verification Record

- macOS: three ordinary-user RSD/AFC connection and teardown cycles passed. USB
  discovery reported zero attached devices with no discovery error.
- macOS: a physical 12 MiB AFC upload/download matched every byte and the temporary
  remote file was removed. An existing development-signed IPA containing one
  extension installed, passed bundle verification, and launched over this tunnel.
  The IPA was approximately 2.07 MiB compressed; the larger payload proof uses the
  separate AFC file rather than claiming a large-IPA install.
- Deterministic tests cover a 12 MiB concurrent-stream round trip, valid TCP
  checksums, MTU limits, retransmission after dropped outbound payload, unanswered
  dial timeout, stop during a pending dial, singleton rejection, and sequential
  teardown/recreation. An RSD regression test checks that the injected socket
  factory survives into an advertised AppService connection.
- The synthetic peer now retransmits unacknowledged echo responses: under full
  suite contention its earlier simplistic echo could lose a response and stall.
  The transport also needed chained inbound buffering to sustain large streams.
- Linux Ubuntu 24.04 / Swift 6.2.4: 92 selected DeviceKit and plist regression
  tests passed as an ordinary user with effective capabilities zero. The 12 MiB
  stream, timeout/cancellation, retransmission, and teardown tests all passed.
- Full macOS `swift test` passed after the TLS fix: 315 tests. Swift format lint passed for changed
  CLI, DeviceKit, and test files. Full Linux `swift test` passed after the TLS fix: 307 tests on
  Swift 6.2.4 with effective capabilities zero.
- Linux physical follow-up used an explicitly authorized temporary copy of the
  mapped pairing and development IPA. Files were streamed over SSH directly into
  a mode-0700 Linux directory with mode-0600 files; credentials were not written
  to Windows. The first attempt failed before opening a tunnel because Pair-Verify
  used the new hostname-derived identity. Its temporary material was removed and
  independently checked. The explicit original-host-identity path has a
  cryptographic regression test on both toolchains. With the identity derived
  from Foundation's original hostname, Linux passed all three consecutive
  wireless runs. Each included a 12 MiB AFC upload/download and byte comparison,
  temporary-file removal, extension-bearing development-IPA installation, exact
  bundle verification, staged-IPA removal, and AppService launch. The process ran
  as an ordinary user with effective capabilities zero. An independent check
  confirmed zero USB-attached devices with no discovery error, and verified
  deletion of the temporary pairing, host-identity file, and IPA.
- The macOS first-success/second-reset failure was reproduced while the phone
  remained unlocked. A bounded diagnostic trace established that cancellation
  left `SSL_R_UNEXPECTED_EOF_WHILE_READING` in a relay worker's thread-local
  OpenSSL error queue. When Dispatch reused that worker, `SSL_get_error` interpreted
  the next nonblocking read as a fatal TLS error rather than WANT_READ; the second
  tunnel failed before forwarding its first TCP SYN. The observed RSD reset was
  a consequence of the relay failure.
- CoreDevice TLS now calls `ERR_clear_error()` immediately before each handshake,
  read, and write, following [OpenSSL's error-queue requirement](https://docs.openssl.org/3.5/man3/SSL_get_error/).
  Genuine errors from the current operation remain visible to `SSL_get_error`.
  A test-only loopback TLS-PSK peer waits for an outbound packet before echoing
  it and closing cleanly. The regression seeds an OpenSSL error on the exact
  calling thread: it failed with relay READ_FAILED (6) before the fix and passes
  after it on macOS and Linux. It requires no pairing credentials or device.
  Temporary trace instrumentation was removed after diagnosis.
- After the fix, all three consecutive macOS physical runs passed in one process,
  without trace instrumentation or a delay between runs. Each included the
  12 MiB AFC byte-verified round trip and removal, extension-bearing development
  IPA installation, exact bundle verification, staged-IPA removal, AppService
  launch, and joined-worker teardown. Execution used the ordinary deployment
  account. An independent inventory confirmed zero attached USB devices with no
  discovery error. This closes the observed repeated-install
  reset; broader failure-mode and minimum-host qualification remain open.
- Post-release macOS validation checked the installed 0.0.20 binary's checksum,
  then passed three consecutive wireless runs through its `coredevice-helper
  run-network` entrypoint as the ordinary deployment account. This calls the same
  `NativeNetworkRunner` used by normal `run --network`. The existing signed IPA
  installed, verified, had its staged copy removed, and launched each time. USB
  inventory before and after reported zero devices with no error. The normal
  build-and-run attempt stopped before transport because Swift 6.4 rejects a
  non-Sendable JavaScriptCore callback result in the test app; its complete build
  workflow remains unqualified until that app-source issue is fixed.

## Limits And Remaining Qualification

This is a feasibility spike. lwIP's raw NO_SYS API uses process-global state, so
there is one active stack per process. A second stack fails explicitly with EBUSY.
There are at most 16 active streams; dial setup is serialized, while established
streams operate concurrently. The stack is IPv6/TCP only. The interface MTU is
clamped to at most 1500 and rejects a handshake MTU below 1280.

Buffers are bounded: an 8 MiB lwIP heap, 32 KiB outbound storage per bridge, and
at most 65535 bytes of pending inbound pbuf data per bridge, plus socket and lwIP
pools. `tcp_recved` advances when bytes enter the local stream, so local socket
backpressure reaches the device. Datagram output failure relies on TCP recovery.
Normal local stream close and teardown abort the PCB; graceful local TCP half-close
is not implemented. Remote FIN waits for queued inbound bytes before stream EOF.
TLS relay errors currently surface through closed service streams rather than
retaining a detailed relay result. Hard process termination cannot guarantee
remote staging cleanup.

After promotion in 0.0.20, continue qualification in this order:

1. Qualify the supported minimum macOS/toolchain and a larger extension-bearing
   IPA on both hosts. Three consecutive physical install/launch runs passed on
   macOS after the TLS fix and previously on Linux.
2. Qualify device lock, network loss, relay budget expiry, cancellation during AFC
   staging, stream exhaustion, and meaningful relay error reporting.
3. Decide whether one tunnel per process is sufficient or whether a different
   stack integration is required for concurrent devices.
4. Consider migrating wireless crash diagnostics separately. The install path is
   promoted behind `UserspaceCoreDeviceTunnel` in DeviceKit, with README, bundled
   CLI skill, and GUI behavior updated together. Keep initial device pairing as
   a separate qualification gate.
