import Foundation

/// The provisioning-profile kind. Mirrors the development/distribution split.
public enum ProfileKind: String, Sendable {
    case development
    case distribution

    public var directoryName: String { rawValue }
}

/// Content-addressed storage and lookup for provisioned provisioning profiles.
///
/// Profiles are persisted under `profiles/<kind>/<bundleID>.mobileprovision`
/// (canonical), but `locate` also accepts the legacy flat `profiles/*.mobileprovision`
/// layout and validates a candidate by its parsed content (bundle ID + kind) rather
/// than by its file name. This removes the filename-only collisions and the manual
/// delete-and-recopy steps that earlier provisioning workflows required.
public enum ProfileStore {
    /// The canonical directory for one profile kind under a credential `home`.
    public static func directory(home: URL, kind: ProfileKind) -> URL {
        home.appendingPathComponent("profiles/\(kind.directoryName)", isDirectory: true)
    }

    /// The canonical file path for one bundle ID and kind under a credential `home`.
    public static func profileURL(home: URL, kind: ProfileKind, bundleID: String) -> URL {
        directory(home: home, kind: kind).appendingPathComponent("\(bundleID).mobileprovision")
    }

    /// Atomically stores a downloaded profile at its canonical path with mode `0600`.
    @discardableResult
    public static func store(_ data: Data, home: URL, kind: ProfileKind, bundleID: String) throws -> URL {
        let url = profileURL(home: home, kind: kind, bundleID: bundleID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path)
        return url
    }

    /// Locates a stored profile for a kind and bundle ID, preferring the canonical path
    /// and then falling back to any `.mobileprovision` whose decoded content matches the
    /// requested kind and bundle under the credential `home` (including the legacy flat
    /// layout). Returns nil when no matching profile is present.
    public static func locate(home: URL, kind: ProfileKind, bundleID: String) throws -> URL? {
        let canonical = profileURL(home: home, kind: kind, bundleID: bundleID)
        if let parsed = try? MobileProvisionParser.parse(at: canonical),
           matches(parsed, kind: kind, bundleID: bundleID) {
            return canonical
        }

        // Legacy / alternate layout: scan every profile file under `profiles/` and pick
        // the one whose decoded content matches this kind and bundle.
        let profilesRoot = home.appendingPathComponent("profiles", isDirectory: true)
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: profilesRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants])
        else {
            return nil
        }
        for url in urls where url.pathExtension == "mobileprovision" {
            guard let profile = try? MobileProvisionParser.parse(at: url) else { continue }
            if matches(profile, kind: kind, bundleID: bundleID) {
                return url
            }
        }
        return nil
    }

    /// Locates a profile for a kind `bundleID`, failing loudly with an actionable error
    /// when none is present.
    public static func requireFound(home: URL, kind: ProfileKind, bundleID: String) throws -> URL {
        guard let url = try locate(home: home, kind: kind, bundleID: bundleID) else {
            throw Error.profileMissing(kind, bundleID)
        }
        return url
    }

    /// True when a parsed profile authorizes the exact bundle ID for the given kind.
    /// The bundle is read from the profile's `application-identifier` entitlement (which
    /// is `TEAMID.<bundle>`; team IDs contain no dots) and the kind from `get-task-allow`.
    public static func matches(
        _ profile: MobileProvisionParser.ProvisioningProfile, kind: ProfileKind, bundleID: String
    ) -> Bool {
        guard let applicationIdentifier = profile.entitlements["application-identifier"] as? String,
            applicationIdentifier.hasSuffix("." + bundleID)
        else {
            return false
        }
        let allowDevice =
            profile.entitlements["get-task-allow"] as? Bool
            ?? (profile.profileType == "Development" ? true : false)
        let isDevelopment = allowDevice
        switch kind {
        case .development:
            return isDevelopment
        case .distribution:
            return !isDevelopment
        }
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case profileMissing(ProfileKind, String)

        public var description: String {
            switch self {
            case let .profileMissing(kind, bundleID):
                let command =
                    kind == .development
                    ? "stupid-app signing setup --kind development --bundle-id \(bundleID) --udid <udid>"
                    : "stupid-app signing setup --kind distribution --bundle-id \(bundleID)"
                return "No \(kind.rawValue) provisioning profile is stored for '\(bundleID)'. Run `\(command)` first."
            }
        }
    }
}