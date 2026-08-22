import Foundation

/// Validates that a parsed provisioning profile satisfies the requested signing target
/// before any expensive build or signing work runs. Returns nil when the profile is
/// usable, otherwise a public-safe, actionable failure.
///
/// This closes the loop on the stale/mismatched-profile failures surfaced during device
/// runs: a profile that does not contain the target device (development) or does not
/// authorize the exact bundle/team must be re-provisioned rather than reused blindly.
public enum ProfilePreflight {
    public enum Kind {
        case development
        case distribution
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case notDevelopment
        case teamMismatch(String)
        case bundleMismatch(expected: String, profile: String)
        case deviceMissing(String)
        case expired(Date)

        public var description: String {
            switch self {
            case .notDevelopment:
                return "The selected profile is a distribution profile, not a development profile."
            case let .teamMismatch(teamID):
                return "The profile team does not contain '\(teamID)'. Re-run `stupid-app signing setup`."
            case let .bundleMismatch(expected, profile):
                return "The profile authorizes '\(profile)' but the project targets '\(expected)'. Re-run `stupid-app signing setup` for this bundle."
            case let .deviceMissing(udid):
                return "The development profile does not provision device '\(udid)'. Re-run `stupid-app signing setup --kind development --udid \(udid)` to add it."
            case let .expired(date):
                return "The provisioning profile expired on \(date). Re-run `stupid-app signing setup`."
            }
        }
    }

    public static func validate(
        _ profile: MobileProvisionParser.ProvisioningProfile,
        kind: ProfileKind,
        teamID: String,
        bundleID: String,
        deviceUDID: String? = nil
    ) throws {
        let isDevelopmentProfile =
            profile.entitlements["get-task-allow"] as? Bool
            ?? (profile.profileType == "Development" ? true : false)
        if kind == .development && !isDevelopmentProfile {
            throw Error.notDevelopment
        }

        if !profile.teamIdentifier.contains(teamID) {
            throw Error.teamMismatch(teamID)
        }

        guard let applicationIdentifier = profile.entitlements["application-identifier"] as? String else {
            throw Error.teamMismatch(teamID)
        }
        let expectedApplicationIdentifier = "\(teamID).\(bundleID)"
        if applicationIdentifier != expectedApplicationIdentifier {
            throw Error.bundleMismatch(
                expected: expectedApplicationIdentifier, profile: applicationIdentifier)
        }

        if let expiry = profile.expirationDate {
            // Guard against a slightly stale local clock.
            let margin = Date().addingTimeInterval(60)
            if expiry < margin {
                throw Error.expired(expiry)
            }
        }

        if let deviceUDID, kind == .development {
            if !profile.provisionedDevices.contains(deviceUDID) {
                throw Error.deviceMissing(deviceUDID)
            }
        }
    }
}