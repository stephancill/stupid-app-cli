import argparse
import asyncio
import importlib.metadata
import json
import os
import sys
from contextlib import suppress
from pathlib import Path

EXPECTED_VERSIONS = {
    "pymobiledevice3": "8.2.1",
    "construct-typing": "0.7.0",
}


def emit(payload: dict) -> None:
    print(json.dumps(payload, separators=(",", ":")), flush=True)


def require_environment(require_root: bool) -> Path:
    for package, expected in EXPECTED_VERSIONS.items():
        actual = importlib.metadata.version(package)
        if actual != expected:
            raise RuntimeError(
                f"{package} {expected} is required, but {actual} is installed. "
                "Provision the environment with the repository's frozen uv.lock."
            )
    if sys.version_info[:2] != (3, 13):
        raise RuntimeError(
            f"Python 3.13 is required, but {sys.version_info.major}.{sys.version_info.minor} is running."
        )
    if require_root and os.geteuid() != 0:
        raise PermissionError(
            "CoreDevice tunneling requires root/CAP_NET_ADMIN. "
            "Re-run with the explicit --sudo option after authenticating with `sudo -v`."
        )
    if require_root and not os.access("/dev/net/tun", os.R_OK | os.W_OK):
        raise PermissionError("CoreDevice tunneling requires readable and writable /dev/net/tun.")

    value = os.environ.get("STUPID_APP_PAIRING_HOME")
    if not value:
        raise RuntimeError("STUPID_APP_PAIRING_HOME is required.")
    pairing_home = Path(value)
    if not pairing_home.is_absolute():
        raise RuntimeError("STUPID_APP_PAIRING_HOME must be an absolute path.")
    pairing_home.mkdir(parents=True, exist_ok=True, mode=0o700)
    pairing_home.chmod(0o700)

    # pymobiledevice3 otherwise chooses the invoking user's ~/.pymobiledevice3 directory.
    import pymobiledevice3.common

    pymobiledevice3.common._HOMEFOLDER = pairing_home
    return pairing_home


def normalize_pairing_permissions(pairing_home: Path) -> None:
    pairing_home.chmod(0o700)
    sudo_uid = os.environ.get("SUDO_UID")
    sudo_gid = os.environ.get("SUDO_GID")
    if sudo_uid is not None and sudo_gid is not None:
        os.chown(pairing_home, int(sudo_uid), int(sudo_gid))
    for record in pairing_home.glob("*.plist"):
        record.chmod(0o600)
        if sudo_uid is not None and sudo_gid is not None:
            os.chown(record, int(sudo_uid), int(sudo_gid))


def launch_pid(value):
    if isinstance(value, dict):
        for key in ("processIdentifier", "pid"):
            if key in value:
                with suppress(TypeError, ValueError):
                    return int(value[key])
        for nested in value.values():
            result = launch_pid(nested)
            if result is not None:
                return result
    if isinstance(value, list):
        for nested in value:
            result = launch_pid(nested)
            if result is not None:
                return result
    return None


async def pair_usb(args, pairing_home: Path) -> None:
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
    from pymobiledevice3.remote.tunnel_service import (
        CoreDeviceTunnelProxy,
        create_core_device_tunnel_service_using_rsd,
    )

    stage = "lockdown pairing"
    lockdown = None
    proxy = None
    rsd = None
    core = None
    try:
        lockdown = await asyncio.wait_for(
            create_using_usbmux(
                serial=args.udid,
                autopair=True,
                pair_timeout=args.timeout,
                pairing_records_cache_folder=pairing_home,
                usbmux_address=args.usbmux,
            ),
            timeout=args.timeout,
        )
        stage = "enabling wireless connections"
        await lockdown.set_enable_wifi_connections(True)
        if not await lockdown.get_enable_wifi_connections():
            raise RuntimeError("The device did not enable wireless lockdown connections.")
        stage = "CoreDevice proxy creation"
        proxy = await CoreDeviceTunnelProxy.create(lockdown)
        stage = "USB CoreDevice tunnel creation"
        async with proxy.start_tcp_tunnel() as tunnel:
            rsd = RemoteServiceDiscoveryService((tunnel.address, tunnel.port))
            stage = "Remote Service Discovery connection"
            await asyncio.wait_for(rsd.connect(), timeout=args.timeout)
            if rsd.udid != args.udid:
                raise RuntimeError("The CoreDevice tunnel resolved a different device.")
            stage = "CoreDevice remote pairing"
            core = await asyncio.wait_for(
                create_core_device_tunnel_service_using_rsd(rsd, autopair=True),
                timeout=args.timeout,
            )
    except TimeoutError as error:
        raise RuntimeError(f"{stage} timed out after {args.timeout} seconds.") from error
    finally:
        if core is not None:
            with suppress(Exception):
                await core.close()
            rsd = None
        if rsd is not None:
            with suppress(Exception):
                await rsd.close()
        if proxy is not None:
            with suppress(Exception):
                await proxy.close()
        if lockdown is not None:
            with suppress(Exception):
                await lockdown.close()
        normalize_pairing_permissions(pairing_home)


async def launch_connected(rsd, bundle_id: str, timeout: int) -> int:
    from pymobiledevice3.remote.core_device.app_service import AppServiceService

    async with AppServiceService(rsd) as app_service:
        result = await asyncio.wait_for(
            app_service.launch_application(
                bundle_id=bundle_id,
                arguments=[],
                kill_existing=True,
                start_suspended=False,
            ),
            timeout=timeout,
        )
    pid = launch_pid(result)
    if pid is None:
        raise RuntimeError("The launch response did not contain a process identifier.")
    return pid


async def launch_usb(args, pairing_home: Path) -> int:
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
    from pymobiledevice3.remote.tunnel_service import CoreDeviceTunnelProxy

    lockdown = await create_using_usbmux(
        serial=args.udid,
        pairing_records_cache_folder=pairing_home,
        usbmux_address=args.usbmux,
    )
    proxy = None
    rsd = None
    try:
        proxy = await CoreDeviceTunnelProxy.create(lockdown)
        async with proxy.start_tcp_tunnel() as tunnel:
            rsd = RemoteServiceDiscoveryService((tunnel.address, tunnel.port))
            await asyncio.wait_for(rsd.connect(), timeout=args.timeout)
            if rsd.udid != args.udid:
                raise RuntimeError("The CoreDevice tunnel resolved a different device.")
            return await launch_connected(rsd, args.bundle_id, args.timeout)
    finally:
        if rsd is not None:
            with suppress(Exception):
                await rsd.close()
        if proxy is not None:
            with suppress(Exception):
                await proxy.close()
        with suppress(Exception):
            await lockdown.close()


def address_score(value: str):
    if value.startswith(("192.168.", "10.")) or value.startswith("172."):
        return (0, value)
    if ":" not in value:
        return (1, value)
    if value.lower().startswith("fe80:"):
        return (2, value)
    return (3, value)


async def run_network(args) -> int:
    from pymobiledevice3.bonjour import browse_remotepairing
    from pymobiledevice3.pair_records import iter_remote_paired_identifiers
    from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
    from pymobiledevice3.remote.tunnel_service import (
        TunnelProtocol,
        create_core_device_tunnel_service_using_remotepairing,
        start_tunnel,
    )
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    advertisements = await asyncio.wait_for(
        browse_remotepairing(timeout=args.discovery_timeout),
        timeout=args.discovery_timeout + 2,
    )
    identifiers = sorted(set(iter_remote_paired_identifiers()))
    if not identifiers:
        raise RuntimeError("No remote pairing record exists. Run `stupid-app device pair --usb` first.")
    if not advertisements:
        raise RuntimeError(
            "No iPhone remote-pairing service was discovered. Confirm the phone is unlocked, "
            "on the same network, and disconnected from USB."
        )

    candidates = []
    seen_candidates = set()
    for answer in advertisements:
        if answer.port is None:
            continue
        for address in sorted(answer.addresses, key=lambda item: address_score(item.full_ip)):
            for identifier in identifiers:
                candidate = (identifier, address.full_ip, answer.port)
                if candidate not in seen_candidates:
                    seen_candidates.add(candidate)
                    candidates.append(candidate)

    failures = []
    for index, (identifier, address, port) in enumerate(candidates, start=1):
        service = None
        rsd = None
        stage = "remote-pairing connection"
        try:
            service = await asyncio.wait_for(
                create_core_device_tunnel_service_using_remotepairing(
                    identifier,
                    address,
                    port,
                    autopair=False,
                ),
                timeout=args.discovery_timeout,
            )
            stage = "TCP tunnel creation"
            async with start_tunnel(service, protocol=TunnelProtocol.TCP) as tunnel:
                service = None
                rsd = RemoteServiceDiscoveryService((tunnel.address, tunnel.port))
                stage = "Remote Service Discovery connection"
                await asyncio.wait_for(rsd.connect(), timeout=args.discovery_timeout)
                if rsd.udid != args.udid:
                    failures.append(f"candidate {index}: different device")
                    continue

                stage = "application installation"
                async with InstallationProxyService(lockdown=rsd) as installer:
                    await asyncio.wait_for(
                        installer.install_from_local(args.ipa, developer=True),
                        timeout=args.install_timeout,
                    )
                    apps = await asyncio.wait_for(
                        installer.get_apps(bundle_identifiers=[args.bundle_id]),
                        timeout=min(args.launch_timeout, 30),
                    )
                    if args.bundle_id not in apps:
                        raise RuntimeError("Installation completed but the app is not present on the device.")

                stage = "application launch"
                return await launch_connected(rsd, args.bundle_id, args.launch_timeout)
        except Exception as error:
            errno = getattr(error, "errno", None)
            suffix = f" errno={errno}" if errno is not None else ""
            reason = getattr(error, "reason", None)
            if reason:
                suffix += f" reason={reason}"
            failures.append(f"candidate {index} {stage}: {type(error).__name__}{suffix}")
        finally:
            if rsd is not None:
                with suppress(Exception):
                    await rsd.close()
            if service is not None:
                with suppress(Exception):
                    await service.close()

    detail = ", ".join(failures[-20:]) if failures else "no usable candidates"
    raise RuntimeError(f"No network tunnel reached the selected device ({detail}).")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)

    check = commands.add_parser("check")
    check.add_argument("--require-root", action="store_true")

    pair = commands.add_parser("pair-usb")
    pair.add_argument("--udid", required=True)
    pair.add_argument("--usbmux")
    pair.add_argument("--timeout", type=int, default=30)

    usb_launch = commands.add_parser("launch-usb")
    usb_launch.add_argument("--udid", required=True)
    usb_launch.add_argument("--usbmux")
    usb_launch.add_argument("--bundle-id", required=True)
    usb_launch.add_argument("--timeout", type=int, default=60)

    network = commands.add_parser("run-network")
    network.add_argument("--udid", required=True)
    network.add_argument("--ipa", type=Path, required=True)
    network.add_argument("--bundle-id", required=True)
    network.add_argument("--discovery-timeout", type=int, default=15)
    network.add_argument("--install-timeout", type=int, default=300)
    network.add_argument("--launch-timeout", type=int, default=60)
    return root


async def main() -> None:
    os.umask(0o077)
    args = parser().parse_args()
    pairing_home = require_environment(args.command != "check" or args.require_root)
    if args.command == "check":
        emit({"status": "ok", "operation": "check"})
    elif args.command == "pair-usb":
        await pair_usb(args, pairing_home)
        emit({"status": "ok", "operation": "pair-usb"})
    elif args.command == "launch-usb":
        pid = await launch_usb(args, pairing_home)
        emit({"status": "ok", "operation": "launch-usb", "pid": pid})
    else:
        pid = await run_network(args)
        emit({"status": "ok", "operation": "run-network", "pid": pid})


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as error:
        emit({"status": "error", "type": type(error).__name__, "error": str(error)})
        raise SystemExit(1)
