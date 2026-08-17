import Foundation
import ProjectCore
import SDKCore

/// Discovers the active iOS SDK version from the installed, validated `stupid-app`
/// Swift SDK bundle. The packer uses the **SDK version**, not the deployment target,
/// as the linker platform version so `LC_BUILD_VERSION` reports the real SDK. This
/// corrects the referenced xtool weakness on non-macOS hosts.
public enum SDKVersion {
    /// Errors are actionable and name the failing phase and a safe recovery step.
    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case sdkNotInstalled(String)
        case bundleNotFound(String)
        case manifestUnreadable(String)
        case sdkVersionMissing(String)

        public var description: String {
            switch self {
            case let .sdkNotInstalled(id):
                return "Swift SDK '\(id)' is not installed. Run `stupid-app sdk import` first."
            case let .bundleNotFound(id):
                return "Installed Swift SDK '\(id)' exists but its artifact bundle could not be located. Re-run `stupid-app sdk import <archive>`."
            case let .manifestUnreadable(path):
                return "Could not read the SDK manifest at '\(path)'."
            case let .sdkVersionMissing(path):
                return "SDK manifest at '\(path)' declares no iphoneosSDKVersion."
            }
        }
    }

    /// Resolves the SDK version. An explicit `--sdk-version` override always wins;
    /// otherwise the installed bundle's `sdk-manifest.json` is read. On macOS with no
    /// installed `stupid-app` SDK, `xcrun` reports the Xcode SDK version as a fallback
    /// for local comparison builds only.
    public static func resolve(
        sdkID: String = "stupid-app-ios",
        targetTriple: String = "arm64-apple-ios",
        swiftPath: String = "swift",
        override: String? = nil
    ) throws -> String {
        if let override {
            guard AppConfig.isValidVersion(override) else {
                throw ProjectError.invalidDeploymentTarget(override)
            }
            return override
        }

        do {
            let manifest = try installedManifest(
                sdkID: sdkID,
                targetTriple: targetTriple,
                swiftPath: swiftPath
            )
            return manifest.iphoneosSDKVersion
        } catch {
            // fall through to macOS fallback only for real errors; sdkNotInstalled is
            // expected when no SDK is installed.
            if case Error.sdkNotInstalled = error {
                // continue below
            } else {
                throw error
            }
        }

        #if os(macOS)
        return try macOSSDKVersion()
        #else
        throw Error.sdkNotInstalled(sdkID)
        #endif
    }

    /// Lists installed Swift SDK artifact IDs by parsing `swift sdk list`.
    public static func installedSDKs(swiftPath: String = "swift") throws -> [String] {
        let swift = HostInfo.resolveExecutable(swiftPath)
        let result = try ProcessRunner.run(executable: swift, arguments: ["sdk", "list"])
        guard result.succeeded else {
            throw Error.sdkNotInstalled("any")
        }
        let lines = result.stdout.split(separator: "\n").map(String.init)
        guard !lines.contains(where: { $0.lowercased().contains("no swift sdk") }) else {
            return []
        }
        return lines
    }

    /// True when the named SDK is registered with SwiftPM.
    public static func isInstalled(sdkID: String, swiftPath: String = "swift") -> Bool {
        guard let installed = try? installedSDKs(swiftPath: swiftPath) else { return false }
        return installed.contains(sdkID)
    }

    /// Reads the manifest from an installed Swift SDK artifact bundle.
    public static func installedManifest(
        sdkID: String,
        targetTriple: String = "arm64-apple-ios",
        swiftPath: String = "swift"
    ) throws -> SDKManifest {
        guard let bundleURL = try installedBundle(
            sdkID: sdkID,
            targetTriple: targetTriple,
            swiftPath: swiftPath
        ) else {
            throw Error.sdkNotInstalled(sdkID)
        }
        let manifestURL = bundleURL.appendingPathComponent("sdk-manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw Error.manifestUnreadable(manifestURL.path)
        }
        let manifest = try SDKManifest.decode(data)
        guard !manifest.iphoneosSDKVersion.isEmpty else {
            throw Error.sdkVersionMissing(manifestURL.path)
        }
        return manifest
    }

    /// Locates the installed artifact bundle root by walking the configured SDK
    /// resources path up to the bundle root. Returns nil when the SDK is not installed.
    static func installedBundle(sdkID: String, targetTriple: String, swiftPath: String) throws -> URL? {
        let swift = HostInfo.resolveExecutable(swiftPath)
        let result = try ProcessRunner.run(
            executable: swift,
            arguments: ["sdk", "configure", sdkID, targetTriple, "--show-configuration"]
        )
        if result.exitStatus != 0 {
            if result.stderr.contains("not currently installed") || result.stderr.contains("not installed") {
                throw Error.sdkNotInstalled(sdkID)
            }
            throw Error.bundleNotFound(sdkID)
        }

        let prefix = "swiftResourcesPath: "
        guard let line = result.stdout.split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) })?
            .dropFirst(prefix.count) else {
            // Some SwiftPM versions print JSON configuration. Attempt a JSON fallback.
            guard let data = result.stdout.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resourcesPath = json["swiftResourcesPath"] as? String ?? JSONObject.firstString(json, keys: ["swiftResourcesPath"])
            else {
                throw Error.bundleNotFound(sdkID)
            }
            return bundleRoot(fromResources: resourcesPath)
        }

        return bundleRoot(fromResources: String(line))
    }

    /// Walks the `swift/iphoneos` resources path (6 components under the bundle root)
    /// up to the artifact bundle root.
    private static func bundleRoot(fromResources resourcesPath: String) -> URL {
        var url = URL(fileURLWithPath: resourcesPath)
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    #if os(macOS)
    private static func macOSSDKVersion() throws -> String {
        let result = try ProcessRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["--sdk", "iphoneos", "--show-sdk-version"]
        )
        guard result.succeeded, !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.sdkNotInstalled("ipaoneos (Xcode)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif
}

private enum JSONObject {
    static func firstString(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                return value
            }
        }
        for value in object.values {
            if let nested = value as? [String: Any], let found = firstString(nested, keys: keys) {
                return found
            }
        }
        return nil
    }
}
