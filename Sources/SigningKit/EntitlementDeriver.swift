import Foundation
import ProjectCore

/// Derives the final entitlements for one signing pass from the source
/// `App.entitlements` and validates them against the selected provisioning profile.
/// This is the explicit data flow required by the project: source entitlement plist ->
/// typed requested entitlements -> profile reconciliation -> final entitlements.
public enum EntitlementDeriver {
    public enum Configuration: Sendable {
        case development
        case distribution
    }

    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case sourceUnreadable(String)
        case unsupportedEntitlement(String)
        case notAuthorizedByProfile(String)
        case teamMismatch
        case applicationIdentifierMismatch(expected: String, profile: String)

        public var description: String {
            switch self {
            case let .sourceUnreadable(path):
                return "Could not read entitlements at '\(path)'."
            case let .unsupportedEntitlement(key):
                return "Entitlement '\(key)' is not supported in version 1; remove it from App.entitlements."
            case let .notAuthorizedByProfile(key):
                return "Entitlement '\(key)' is not authorized by the selected provisioning profile."
            case .teamMismatch:
                return "The provisioning profile team does not match the signing certificate team."
            case let .applicationIdentifierMismatch(expected, profile):
                return "Application identifier '\(expected)' does not match the profile's '\(profile)'."
            }
        }
    }

    /// Known simple boolean entitlements with no capability association; anything else
    /// outside this set is rejected loudly in version 1.
    public static let supportedKeys: Set<String> = [
        "get-task-allow",
        "application-identifier",
        "com.apple.developer.team-identifier",
        "keychain-access-groups",
        "com.apple.developer.applesignin",
        "com.apple.developer.associated-domains",
        "application-groups",
    ]

    /// Reads the source entitlements plist, forces the `get-task-allow` value for the
    /// configuration, and reconciles the derived entitlements with the profile.
    /// - Returns: the final entitlement dictionary.
    public static func derive(
        sourceURL: URL,
        configuration: Configuration,
        bundleID: String,
        profile: MobileProvisionParser.ProvisioningProfile,
        teamID: String
    ) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: sourceURL) else {
            throw Error.sourceUnreadable(sourceURL.path)
        }
        guard let requested = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw Error.sourceUnreadable("\(sourceURL.path) is not a plist dictionary")
        }

        // Reject unsupported entitlements before doing anything else.
        for key in requested.keys where !supportedKeys.contains(key) {
            throw Error.unsupportedEntitlement(key)
        }

        var derived = requested

        // get-task-allow: true for development, false for distribution.
        derived["get-task-allow"] = (configuration == .development)

        // application-identifier and team-identifier are derived from the bundle ID.
        let applicationIdentifier = "\(teamID).\(bundleID)"
        derived["application-identifier"] = applicationIdentifier
        derived["com.apple.developer.team-identifier"] = teamID

        // Reconcile: every requested entitlement must be authorized by the profile.
        let profileEntitlements = profile.entitlements
        for (key, value) in derived {
            guard let profileValue = profileEntitlements[key] else {
                throw Error.notAuthorizedByProfile(key)
            }
            // Application identifier differs by prefix expansion; validate containment.
            if key == "application-identifier" {
                let profileApplicationID = profileValue as? String ?? ""
                let stripped = profileApplicationID.replacingOccurrences(of: "\(teamID).", with: "")
                if stripped != bundleID {
                    throw Error.applicationIdentifierMismatch(
                        expected: applicationIdentifier,
                        profile: profileApplicationID
                    )
                }
            } else if let profileString = profileValue as? String, let valueString = value as? String {
                if profileString != valueString {
                    throw Error.notAuthorizedByProfile("\(key) value mismatch")
                }
            } else if let profileArray = profileValue as? [Any], let valueArray = value as? [Any] {
                let left = (profileArray as? [String]).map { Set($0) }
                let right = (valueArray as? [String]).map { Set($0) }
                if let left, let right, !right.isSubset(of: left) {
                    throw Error.notAuthorizedByProfile("\(key) value mismatch")
                }
            }
        }

        return derived
    }

    /// Writes the final entitlement dictionary as an XML plist.
    public static func writeXML(_ entitlements: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }
}