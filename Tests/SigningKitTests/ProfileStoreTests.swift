import Foundation
import Testing
@testable import SigningKit

/// Unit tests for the development/profile preflight and content-addressed ProfileStore
/// without real certificates or profiles.
struct ProfilePreflightAndStoreTests {
    private func makeProfileData(_ plist: [String: Any]) throws -> Data {
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let octet = try DERBuilder.wrapOctetString(plistData)
        let eContent = try DERBuilder.wrapExplicitContent(octet)
        let eContentTypeOID = Data(
            [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01])
        let encapContentInfo = try DERBuilder.wrapSequence(eContentTypeOID + eContent)
        let sha256Alg = Data(
            [0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00])
        let digestAlgorithms = try DERBuilder.wrapSet(sha256Alg)
        let version = Data([0x02, 0x01, 0x01])
        let signedData = try DERBuilder.wrapSequence(version + digestAlgorithms + encapContentInfo)
        let content = try DERBuilder.wrapExplicitContent(signedData)
        let contentTypeOID = Data(
            [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02])
        return try DERBuilder.wrapSequence(contentTypeOID + content)
    }

    private func developmentPlist(deviceUDIDs: [String] = ["DEVICE-1"]) -> [String: Any] {
        [
            "TeamIdentifier": ["TEAMID1234"],
            "ApplicationIdentifierPrefix": ["TEAMID1234"],
            "ProvisionedDevices": deviceUDIDs,
            "ProfileType": "Development",
            "Entitlements": [
                "application-identifier": "TEAMID1234.net.example.app",
                "com.apple.developer.team-identifier": "TEAMID1234",
                "get-task-allow": true,
            ] as [String: Any],
            "ExpirationDate": Date(timeIntervalSinceNow: 86_400 * 30),
        ]
    }

    @Test("preflight accepts a current development profile for the target device")
    func preflightAccepts() throws {
        let profile = MobileProvisionParser.ProvisioningProfile(plist: developmentPlist())
        try ProfilePreflight.validate(
            profile, kind: .development, teamID: "TEAMID1234", bundleID: "net.example.app",
            deviceUDID: "DEVICE-1")
    }

    @Test("preflight rejects a profile that misses the target device")
    func preflightRejectsMissingDevice() {
        let profile = MobileProvisionParser.ProvisioningProfile(plist: developmentPlist(deviceUDIDs: ["OTHER"]))
        #expect(throws: ProfilePreflight.Error.self) {
            try ProfilePreflight.validate(
                profile, kind: .development, teamID: "TEAMID1234", bundleID: "net.example.app",
                deviceUDID: "DEVICE-1")
        }
    }

    @Test("preflight rejects a distribution profile for a development run")
    func preflightRejectsDistributionProfile() {
        var plist = developmentPlist()
        plist["ProfileType"] = "Distribution"
        var entitlements = plist["Entitlements"] as! [String: Any]
        entitlements["get-task-allow"] = false
        plist["Entitlements"] = entitlements
        let profile = MobileProvisionParser.ProvisioningProfile(plist: plist)
        #expect(throws: ProfilePreflight.Error.notDevelopment) {
            try ProfilePreflight.validate(
                profile, kind: .development, teamID: "TEAMID1234", bundleID: "net.example.app",
                deviceUDID: "DEVICE-1")
        }
    }

    @Test("ProfileStore matches a stored profile by content kind and bundle")
    func storeMatchesByContent() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("profiles-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let data = try makeProfileData(developmentPlist())
        let url = try ProfileStore.store(data, home: home, kind: .development, bundleID: "net.example.app")

        let located = try ProfileStore.locate(home: home, kind: .development, bundleID: "net.example.app")
        #expect(located?.path == url.path)
        #expect(try ProfileStore.locate(home: home, kind: .distribution, bundleID: "net.example.app") == nil)
    }

    @Test("ProfileStore finds a legacy flat profile by content, not name")
    func locateDetectsLegacyLayout() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("profiles-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("profiles", isDirectory: true), withIntermediateDirectories: true)

        let data = try makeProfileData(developmentPlist())
        let legacy = home.appendingPathComponent("profiles/legacy-name.mobileprovision")
        try data.write(to: legacy)

        let located = try ProfileStore.locate(home: home, kind: .development, bundleID: "net.example.app")
        #expect(located?.resolvingSymlinksInPath().path == legacy.resolvingSymlinksInPath().path)
    }
}