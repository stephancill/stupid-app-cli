import Foundation
import Testing
@testable import SigningKit

/// Unit tests for the provisioning-profile CMS parser and entitlement derivation using
/// sanitized synthetic fixtures (no real certificates or profiles).
struct MobileProvisionParserTests {
    /// Builds a minimal CMS SignedData structure wrapping a plist payload, matching the
    /// DER layout real `.mobileprovision` files use.
    private func makeProfileData(plist: [String: Any]) throws -> Data {
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        // eContent [0] EXPLICIT OCTET STRING
        let octetString = try DERBuilder.wrapOctetString(plistData)
        let eContent = try DERBuilder.wrapExplicitContent(octetString)
        // encapContentInfo ::= SEQUENCE { eContentType OID, eContent [0] }
        // id-data OID 1.2.840.113549.1.7.1
        let eContentTypeOID = Data([0x06, 0x09]) + Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01])
        let encapContentInfo = try DERBuilder.wrapSequence(eContentTypeOID + eContent)
        // digestAlgorithms SET (empty-ish, one sha256 AlgorithmIdentifier)
        let sha256Alg = Data([0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00])
        let digestAlgorithms = try DERBuilder.wrapSet(sha256Alg)
        // version INTEGER 1
        let version = Data([0x02, 0x01, 0x01])
        // SignedData ::= SEQUENCE { version, digestAlgorithms, encapContentInfo }
        let signedData = try DERBuilder.wrapSequence(version + digestAlgorithms + encapContentInfo)
        // content [0] EXPLICIT SignedData
        let content = try DERBuilder.wrapExplicitContent(signedData)
        // contentType OID: id-signedData 1.2.840.113549.1.7.2
        let contentTypeOID = Data([0x06, 0x09]) + Data([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02])
        return try DERBuilder.wrapSequence(contentTypeOID + content)
    }

    @Test("extracts plist from synthetic CMS profile")
    func syntheticProfile() throws {
        let plist: [String: Any] = [
            "Name": "Test AppStore",
            "UUID": "12345678-1234-1234-1234-123456789012",
            "TeamIdentifier": ["TEAMID1234"],
            "ApplicationIdentifierPrefix": ["TEAMID1234"],
            "ProvisionedDevices": [],
            "ProfileType": "Distribution",
            "Entitlements": [
                "application-identifier": "TEAMID1234.net.example.app",
                "com.apple.developer.team-identifier": "TEAMID1234",
                "get-task-allow": false,
            ] as [String: Any],
            "ExpirationDate": Date(timeIntervalSince1970: 4_100_000_000),
        ]
        let data = try makeProfileData(plist: plist)
        let profile = try MobileProvisionParser.parse(data)

        #expect(profile.name == "Test AppStore")
        #expect(profile.uuid == "12345678-1234-1234-1234-123456789012")
        #expect(profile.teamIdentifier == ["TEAMID1234"])
        #expect(profile.provisionedDevices.isEmpty)
        #expect(profile.entitlements["get-task-allow"] as? Bool == false)
    }

    @Test("rejects non-CMS data")
    func rejectsGarbage() {
        let data = Data("not a profile".utf8)
        #expect(throws: MobileProvisionParser.Error.self) {
            try MobileProvisionParser.parse(data)
        }
    }

    @Test("entitlement derivation forces get-task-allow for distribution")
    func distributionEntitlements() throws {
        let profilePlist: [String: Any] = [
            "TeamIdentifier": ["TEAMID1234"],
            "Entitlements": [
                "application-identifier": "TEAMID1234.net.example.app",
                "com.apple.developer.team-identifier": "TEAMID1234",
                "get-task-allow": false,
            ] as [String: Any],
        ]
        let profile = MobileProvisionParser.ProvisioningProfile(plist: profilePlist)

        let entitlementsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-ent-test-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: entitlementsURL) }
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """.write(to: entitlementsURL, atomically: true, encoding: .utf8)

        let derived = try EntitlementDeriver.derive(
            sourceURL: entitlementsURL,
            configuration: .distribution,
            bundleID: "net.example.app",
            profile: profile,
            teamID: "TEAMID1234"
        )
        #expect(derived["get-task-allow"] as? Bool == false)
        #expect(derived["application-identifier"] as? String == "TEAMID1234.net.example.app")
        #expect(derived["com.apple.developer.team-identifier"] as? String == "TEAMID1234")
    }

    @Test("entitlement derivation forces get-task-allow for development")
    func developmentEntitlements() throws {
        let profilePlist: [String: Any] = [
            "TeamIdentifier": ["TEAMID1234"],
            "Entitlements": [
                "application-identifier": "TEAMID1234.net.example.app",
                "com.apple.developer.team-identifier": "TEAMID1234",
                "get-task-allow": true,
            ] as [String: Any],
        ]
        let profile = MobileProvisionParser.ProvisioningProfile(plist: profilePlist)

        let entitlementsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-ent-test-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: entitlementsURL) }
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """.write(to: entitlementsURL, atomically: true, encoding: .utf8)

        let derived = try EntitlementDeriver.derive(
            sourceURL: entitlementsURL,
            configuration: .development,
            bundleID: "net.example.app",
            profile: profile,
            teamID: "TEAMID1234"
        )
        #expect(derived["get-task-allow"] as? Bool == true)
        #expect(derived["application-identifier"] as? String == "TEAMID1234.net.example.app")
    }

    @Test("unsupported entitlement is rejected loudly")
    func unsupportedEntitlementRejected() throws {
        let profilePlist: [String: Any] = [
            "TeamIdentifier": ["TEAMID1234"],
            "Entitlements": [
                "application-identifier": "TEAMID1234.net.example.app",
                "com.apple.developer.team-identifier": "TEAMID1234",
                "get-task-allow": false,
                "com.apple.developer.icloud-container-identifiers": ["iCloud.net.example"],
            ] as [String: Any],
        ]
        let profile = MobileProvisionParser.ProvisioningProfile(plist: profilePlist)

        let entitlementsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-ent-test-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: entitlementsURL) }
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.net.example</string></array></dict></plist>
        """.write(to: entitlementsURL, atomically: true, encoding: .utf8)

        #expect(throws: EntitlementDeriver.Error.self) {
            try EntitlementDeriver.derive(
                sourceURL: entitlementsURL,
                configuration: .distribution,
                bundleID: "net.example.app",
                profile: profile,
                teamID: "TEAMID1234"
            )
        }
    }

    @Test("capability entitlements are out of scope and rejected loudly in v1")
    func capabilityEntitlementsRejected() throws {
        let profilePlist: [String: Any] = [
            "TeamIdentifier": ["TEAMID1234"],
            "Entitlements": [
                "application-identifier": "TEAMID1234.net.example.app",
                "com.apple.developer.team-identifier": "TEAMID1234",
                "get-task-allow": false,
            ] as [String: Any],
        ]
        let profile = MobileProvisionParser.ProvisioningProfile(plist: profilePlist)

        for capabilityKey in [
            "application-groups",
            "keychain-access-groups",
            "com.apple.developer.applesignin",
            "com.apple.developer.associated-domains",
            "aps-environment",
            "com.apple.developer.icloud-container-identifiers",
        ] {
            let entitlementsURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("stupid-app-ent-test-\(UUID().uuidString).plist")
            defer { try? FileManager.default.removeItem(at: entitlementsURL) }
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>\(capabilityKey)</key><array><string>example</string></array></dict></plist>
            """
            try plist.write(to: entitlementsURL, atomically: true, encoding: .utf8)

            #expect(throws: EntitlementDeriver.Error.self) {
                try EntitlementDeriver.derive(
                    sourceURL: entitlementsURL,
                    configuration: .distribution,
                    bundleID: "net.example.app",
                    profile: profile,
                    teamID: "TEAMID1234"
                )
            }
        }
    }
}

/// Minimal DER building helpers for synthetic CMS fixtures.
enum DERBuilder {
    static func wrapSequence(_ content: Data) throws -> Data {
        try wrap(tag: 0x30, content: content)
    }

    static func wrapSet(_ content: Data) throws -> Data {
        try wrap(tag: 0x31, content: content)
    }

    /// `[0] EXPLICIT` of a constructed value.
    static func wrapExplicitContent(_ content: Data) throws -> Data {
        try wrap(tag: 0xA0, content: content)
    }

    /// An OCTET STRING.
    static func wrapOctetString(_ content: Data) throws -> Data {
        try wrap(tag: 0x04, content: content)
    }

    static func wrap(tag: UInt8, content: Data) throws -> Data {
        let length = try lengthBytes(content.count)
        var result = Data([tag])
        result.append(length)
        result.append(content)
        return result
    }

    static func lengthBytes(_ count: Int) throws -> Data {
        if count < 128 {
            return Data([UInt8(count)])
        }
        var bytes = [UInt8]()
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        var result = Data([UInt8(0x80 | bytes.count)])
        result.append(contentsOf: bytes)
        return result
    }
}