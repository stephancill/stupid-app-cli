# Native Device Diagnostics (crash report, console, installed-app, container fs)

This document defines the device-diagnostic service boundary for `stupid-app`. It extends
the device stack in `DeviceKit` to cover the practical crash- and app-debugging workflow —
pull crash/`.ips` reports, stream the live console, read the installed build, and copy app
containers — so the same commands behave identically on macOS and Linux. The product
invariant is that the deployment host must not require Xcode or macOS at runtime, and Linux
is the production host; no host tool (`devicectl`, Xcode, `pymobiledevice3`, Python) is a
runtime dependency. `devicectl` may be an optional macOS accelerator, never a behavioral
dependency.

## Motivation

A launch-stage crash on a physical iPhone is diagnosed today with a long, hand-driven
`xcrun devicectl` sequence: relaunch with the console attached, list `systemCrashLogs`,
copy the `.ips`, `rg` for termination namespace, then bisect container state. That work
should be a couple of `stupid-app` commands built on the same lockdown services the native
transport already speaks (`USBMuxClient`, `LockdownPairer`, `CoreDeviceTunnel`,
`RemoteXPCService`).

## One backend: the native service layer

There is exactly one backend — native `DeviceKit` services. It is transport-shaped by the
same seam that already splits USB (`NativeUSBInstaller`) from network (`NativeNetworkRunner`
/ `CoreDeviceTunnelService`): a shared connect that returns a lockdown/RSD service channel,
implemented once over the mux and once over the tunnel. A diagnostic command picks the
transport with the existing `--usb` / `--network` flags; neither requires macOS or Xcode.

## Service mapping

| Feature | Device service | Notes |
|---|---|---|
| Crash / `.ips` reports | crash report mover (lockdown) / `systemCrashLogs` files | List + filter (`Jetsam`, bundle, time), copy, parse termination namespace + reason |
| Live console / syslog | `com.apple.syslog_relay` | Stream, filter, bounded by timeout; frame exit reason |
| Installed build lookup | `com.apple.mobile.installation_proxy` (`Lookup`) | Version/build/bundle; surfaces a stale TestFlight build vs repo |
| App-container file copy | `com.apple.afc` (and `house_arrest`) | Reuse existing `AFCClient`; backup/restore a bundle container |

The existing native clients (`NativeUSBInstaller`, `NativeNetworkRunner`) already stage and
install via `com.apple.afc` + `com.apple.mobile.installation_proxy`, so the connection
machinery is present — the diagnostic layer reuses it rather than adding a dependency.

## Command surface

Routes under `device`, matching the existing `device pair` shape:

```text
stupid-app device crash [--path <file>] [--udid <udid>] [--filter <name>] [--network] [--sudo <path>] [--json] [--home <dir>]
stupid-app device console [--udid <udid>] [--filter <predicate>] [--process <name>] [--timeout <sec>] [--usb|--network]
stupid-app device apps [--udid <udid>] [--bundle-id <id>] [--usb|--network]
stupid-app device fs --domain <crash|app|container> [--udid <udid>] [--usb|--network] (<fetch>|<backup>|<restore>) ...
```

Highlights:

- `device crash` prints, for an iOS `.ips` report, the termination namespace + code
  (jetsam/CPU reason when present), the exception, and any application-specific
  detail. It takes a local `--path`, or pulls the newest matching report from a
  `--udid` device over USB (native lockdown + AFC crash-report service) or, with
  `--network`, over the wireless CoreDevice tunnel (`shim.remote`), and parses both
  the JSON `.ips` payload and the legacy text (`cpu_resource`/`jetsam`) reports.
  `--json` emits machine-readable fields. The network pull runs through the
  privileged `coredevice-helper crash-network` subcommand and needs `--sudo` on
  macOS (TUN creation) but is in-process on Linux.
- `device console` streams framed logs and prints `App terminated due to signal N`;
  `--filter`/`--process` drop chatty frames at the source.
- `device apps` reports installed version/build for the project bundle, immediately
  surfacing a TestFlight-vs-repo mismatch.
- `device fs backup`/`restore` copies the app container directory so a persisted-restore
  bug can be bisected without touching the data files.

## Fail-loud defaults

- No silent degradation when a capability is unavailable on a host: the missing host
  dependency (e.g. an unavailable syslog service, unsupported transport) is reported with
  the failing phase, expected condition, and a safe recovery step.
- No command fork background lazily survive cancellation: capture timeout, cancellation, and
  exit states explicitly, per the engineering style / Swift conventions in `AGENTS.md`.

## Out of scope / not parity

- `--start-stopped` debugger attachment is a host tool (LLDB), not a device service. macOS
  uses `devicectl`/LLDB; Linux gains only best-effort support. Do not claim parity or
  silently degrade — must state it.
- Developer-disk-image mounting on a brand-new iOS is best-effort on both hosts.

## Acceptance

- `device crash`, `device console`, `device apps`, and `device fs` run against a paired
  device over USB and network, identical results on macOS and Linux, with no host tool
  invocation.
- `device crash` parses the termination namespace/reason and, where present, the
  exception and application-specific detail; it reads both JSON `.ips` payloads
  and the legacy text (`cpu_resource`/`jetsam`) reports. The local parse, the USB
  and network pull (`crashreportcopymobile` via USB lockdown and
  `crashreportcopymobile.shim.remote` over the CoreDevice tunnel), the
  timestamp-newest selection, and the watchdog/CPU classification are all
  implemented and verified against real `CrashTester` reports on a physical
  iPhone over both USB and the wireless tunnel.

## Next steps

1. Add `SyslogClient` + `device console`, then installed-lookup and container-copy
   behind the same connect seam.
2. Add `--since`/`--output-dir` options to `device crash` to write pulled reports
   locally.
3. Keep `references/commands.md`, the bundled skill, and
   `docs/engineering-handover.md` in sync with each surface change.