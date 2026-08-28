import Foundation

/// Local, credential-free release readiness check. It catches the mistakes App Store
/// Connect otherwise rejects only after an upload: a marketing/build version drift
/// between the app and bundled extensions (`ITMS-90062`/Invalid build class), and a
/// missing or invalid export-compliance declaration (`MISSING_EXPORT_COMPLIANCE`).
///
/// Pure and testable: no credentials, no network.
public enum ReleasePreflight {
    /// The marketing version and build number from one Info.plist.
    public struct VersionPair: Equatable, Sendable {
        public var marketing: String
        public var build: String

        public init(marketing: String, build: String) {
            self.marketing = marketing
            self.build = build
        }
    }

    /// The result of analysing the release-ready project. `isReady` is true only when
    /// every issue has been resolved.
    public struct Assessment: Equatable, Sendable {
        public var appVersion: VersionPair?
        /// Marketing/build per extension bundle ID.
        public var extensions: [String: VersionPair]
        public var issues: [String]

        public init(
            appVersion: VersionPair? = nil,
            extensions: [String: VersionPair] = [:],
            issues: [String] = []
        ) {
            self.appVersion = appVersion
            self.extensions = extensions
            self.issues = issues
        }

        public var isReady: Bool { issues.isEmpty }
    }

    /// The exported export-compliance value. Absent when the key is missing.
    public enum ExportCompliance: Equatable, Sendable {
        case absent
        case declared(Bool)
    }

    /// Assesses the app and every bundled extension against the release gates.
    public static func assess(config: AppConfig, projectRoot: URL) -> Assessment {
        let appURL = projectRoot.appendingPathComponent(config.infoPath)
        var assessment = Assessment()

        guard let app = Self.readVersions(at: appURL) else {
            assessment.issues.append(
                "Could not read CFBundleShortVersionString/CFBundleVersion from '\(appURL.path)'. The app must declare both.")
            return assessment
        }
        assessment.appVersion = app

        // Export compliance must be declared and a real boolean. Declaring it protects
        // against a silent MISSING_EXPORT_COMPLIANCE processing failure later.
        switch Self.readExportCompliance(at: appURL) {
        case .absent:
            assessment.issues.append(
                "Info.plist is missing ITSAppUsesNonExemptEncryption (export compliance). "
                    + "Set it to a Boolean (commonly false when the app uses no exempt encryption), "
                    + "or App Store Connect can reject processing with MISSING_EXPORT_COMPLIANCE.")
        case .declared(true):
            assessment.issues.append(
                "ITSAppUsesNonExemptEncryption=true in \(config.infoPath). A build that declares "
                    + "exempt encryption requires per-build export-compliance review in App Store "
                    + "Connect before external TestFlight. Re-export with false unless the app really "
                    + "uses exempt encryption, or be prepared to answer the compliance questionnaire.")
        case .declared(false):
            break
        }

        // Every extension must share the app's marketing version and build so the repeated
        // Invalid-bundle/ITMS-90062 style rejection cannot happen.
        guard let appVersion = assessment.appVersion else { return assessment }
        for extensionConfig in config.extensions ?? [] {
            let extensionURL = projectRoot.appendingPathComponent(extensionConfig.infoPath)
            guard let extVersions = Self.readVersions(at: extensionURL) else {
                assessment.issues.append(
                    "Could not read CFBundleShortVersionString/CFBundleVersion from '\(extensionURL.path)' "
                        + "(extension '\(extensionConfig.bundleID)').")
                continue
            }
            assessment.extensions[extensionConfig.bundleID] = extVersions
            if extVersions.marketing != appVersion.marketing {
                assessment.issues.append(
                    "Extension '\(extensionConfig.bundleID)' marketing version '\(extVersions.marketing)' "
                        + "drifted from the app '\(appVersion.marketing)'. Bump them in lockstep before uploading.")
            }
            if extVersions.build != appVersion.build {
                assessment.issues.append(
                    "Extension '\(extensionConfig.bundleID)' build '\(extVersions.build)' drifted from "
                        + "the app '\(appVersion.build)'. Bump them in lockstep via `stupid-app release bump`.")
            }
        }

        return assessment
    }

    // MARK: - Plist reads

    public static func readVersions(at url: URL) -> VersionPair? {
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let marketing = plist["CFBundleShortVersionString"] as? String,
            let build = plist["CFBundleVersion"] as? String
        else {
            return nil
        }
        return VersionPair(marketing: marketing, build: build)
    }

    static func readExportCompliance(at url: URL) -> ExportCompliance {
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else {
            return .absent
        }
        guard let value = plist["ITSAppUsesNonExemptEncryption"] else {
            return .absent
        }
        if let bool = value as? Bool {
            return .declared(bool)
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes", "1": return .declared(true)
            case "false", "no", "0": return .declared(false)
            default: return .declared(true)
            }
        }
        return .absent
    }
}