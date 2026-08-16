import BuildCore
import Foundation
import SDKCore

/// Gate 3 device transport: the pinned `pymobiledevice3` CLI over USB (`usbmux`).
/// The transport is replaceable; `stupid-app run` depends only on `DeviceInstaller`.
public struct PyMobileDevice3Installer: DeviceInstaller {
    public var executablePath: String
    /// Optional usbmuxd address passed as `--usbmux`. When nil, the platform
    /// default is used; on Linux a running systemd usbmuxd socket is detected.
    public var usbmuxAddress: String?

    public init(executablePath: String = "pymobiledevice3", usbmuxAddress: String? = nil) {
        self.executablePath = executablePath
        self.usbmuxAddress = usbmuxAddress
    }

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case binaryMissing(String)
        case installFailed(String)
        case launchFailed(String)
        case discoveryFailed(String)

        public var description: String {
            switch self {
            case let .binaryMissing(path):
                return "The pymobiledevice3 CLI is not available at '\(path)'. Install it on the deployment host (e.g. `pip install pymobiledevice3`)."
            case let .installFailed(detail):
                return "Installation failed.\n\(detail)\nConfirm the device is USB-connected, unlocked, and trusted (and that no other device tool is holding usbmuxd)."
            case let .launchFailed(detail):
                return "Launch failed.\n\(detail)\nConfirm Developer Mode is enabled on the device and the app is installed."
            case let .discoveryFailed(detail):
                return "Could not list USB devices.\n\(detail)"
            }
        }
    }

    public func install(ipa: URL, udid: String?) throws {
        let executable = try resolvedExecutable()
        var arguments = ["apps", "install", ipa.path]
        arguments += usbmuxArguments()
        if let udid {
            arguments += ["--udid", udid]
        }
        let result = try ProcessRunner.run(executable: executable, arguments: arguments)
        guard result.succeeded else {
            throw Error.installFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    public func launch(bundleID: String, udid: String?) throws {
        let executable = try resolvedExecutable()
        var arguments = ["developer", "dvt", "launch", bundleID]
        arguments += usbmuxArguments()
        if let udid {
            arguments += ["--udid", udid]
        }
        let result = try ProcessRunner.run(executable: executable, arguments: arguments)
        guard result.succeeded else {
            throw Error.launchFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    /// Resolves the `--usbmux` argument value: an explicit address, or the Linux
    /// systemd usbmuxd unix socket when present.
    private func usbmuxArguments() -> [String] {
        let address = usbmuxAddress ?? defaultLinuxSocket
        guard let address else { return [] }
        return ["--usbmux", address]
    }

    private var defaultLinuxSocket: String? {
        guard usbmuxAddress == nil else { return nil }
        let socket = "/var/run/usbmuxd"
        return FileManager.default.fileExists(atPath: socket) ? socket : nil
    }

    public func usbDeviceUDIDs() throws -> [String] {
        let executable = try resolvedExecutable()
        let result = try ProcessRunner.run(
            executable: executable,
            arguments: ["usbmux", "list", "--usb", "--simple"]
        )
        guard result.succeeded else {
            throw Error.discoveryFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return Self.parseUDIDList(result.stdout)
    }

    /// Normalizes `usbmux list --usb --simple` output into UDID strings, ignoring
    /// empty lines and separating by whitespace.
    public static func parseUDIDList(_ output: String) -> [String] {
        output
            .split(whereSeparator: { $0.isWhitespace || $0 == "\n" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func resolvedExecutable() throws -> String {
        let resolved = HostInfo.resolveExecutable(executablePath)
        guard FileManager.default.isExecutableFile(atPath: resolved) else {
            throw Error.binaryMissing(resolved)
        }
        return resolved
    }
}
