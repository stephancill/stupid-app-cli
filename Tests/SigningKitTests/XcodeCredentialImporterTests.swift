import Crypto
import Foundation
import Testing
@testable import SigningKit

#if canImport(Darwin)

/// Unit tests for the Xcode credential importer's pure logic (identity line parsing,
/// team ID derivation, and exact profile selection). Uses sanitized synthetic fixtures;
/// no real certificates, Keychain, or profiles are touched.
struct XcodeCredentialImporterTests {
  private func certData(_ byte: UInt8) -> Data {
    Data([0x30, 0x03, byte, 0x02, 0x01])
  }

  private func sha1(_ data: Data) -> String {
    Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func profile(
    type: String,
    bundleID: String,
    teamID: String,
    certs: [Data],
    expiration: TimeInterval,
    name: String = "p"
  ) -> MobileProvisionParser.ProvisioningProfile {
    MobileProvisionParser.ProvisioningProfile(plist: [
      "Name": name,
      "ProfileType": type,
      "TeamIdentifier": [teamID],
      "ExpirationDate": Date(timeIntervalSince1970: expiration),
      "DeveloperCertificates": certs,
      "Entitlements": [
        "application-identifier": "\(teamID).\(bundleID)",
        "com.apple.developer.team-identifier": teamID,
        "get-task-allow": type == "Development",
      ] as [String: Any],
    ])
  }

  @Test("parses find-identity lines")
  func parseIdentity() {
    let parsed = XcodeCredentialImporter.parseIdentityLine(
      "  1) ABCDEF0123456789ABCDEF0123456789ABCDEF01  \"Apple Distribution: Name (TEAM1234)\""
    )
    #expect(parsed?.hash == "ABCDEF0123456789ABCDEF0123456789ABCDEF01")
    #expect(parsed?.commonName == "Apple Distribution: Name (TEAM1234)")
  }

  @Test("ignores malformed identity lines")
  func ignoresMalformedIdentity() {
    #expect(XcodeCredentialImporter.parseIdentityLine("no identity here") == nil)
    #expect(XcodeCredentialImporter.parseIdentityLine(
      "1) SHORT  \"Name\""
    ) == nil)
  }

  @Test("derives team ID from common name")
  func teamID() {
    #expect(XcodeCredentialImporter.teamID(fromCN: "Apple Development: Stephan Cilliers (ABC12345)") == "ABC12345")
    #expect(XcodeCredentialImporter.teamID(fromCN: "no parens") == nil)
    #expect(XcodeCredentialImporter.teamID(fromCN: "Apple Development: Stephan Cilliers ()") == nil)
  }

  @Test("selects exact distribution profile by cert and bundle")
  func selectsDistributionProfile() {
    let devCert = certData(0xAA)
    let certSHA1 = sha1(devCert)
    let profiles = [
      profile(type: "Distribution", bundleID: "net.example.app", teamID: "TEAM1", certs: [devCert], expiration: 4_000_000_000, name: "dist"),
      profile(type: "Development", bundleID: "net.example.app", teamID: "TEAM1", certs: [devCert], expiration: 4_000_000_000, name: "dev"),
      profile(type: "Distribution", bundleID: "net.example.other", teamID: "TEAM1", certs: [devCert], expiration: 4_100_000_000, name: "other-bundle"),
    ]
    let chosen = XcodeCredentialImporter.selectProfile(
      from: profiles, bundleID: "net.example.app", kind: .distribution,
      certSHA1: certSHA1, teamID: "TEAM1"
    )
    #expect(chosen?.name == "dist")
  }

  @Test("selects exact development profile by cert and bundle")
  func selectsDevelopmentProfile() {
    let devCert = certData(0xAA)
    let certSHA1 = sha1(devCert)
    let profiles = [
      profile(type: "Distribution", bundleID: "net.example.app", teamID: "TEAM1", certs: [devCert], expiration: 4_000_000_000, name: "dist"),
      profile(type: "Development", bundleID: "net.example.app", teamID: "TEAM1", certs: [devCert], expiration: 4_000_000_000, name: "dev"),
      profile(type: "Development", bundleID: "net.example.other", teamID: "TEAM1", certs: [devCert], expiration: 4_100_000_000, name: "other-bundle"),
    ]
    let chosen = XcodeCredentialImporter.selectProfile(
      from: profiles, bundleID: "net.example.app", kind: .development,
      certSHA1: certSHA1, teamID: "TEAM1"
    )
    #expect(chosen?.name == "dev")
  }

  @Test("rejects wrong team and wrong certificate")
  func rejectsWrongTeamAndCert() {
    let devCert = certData(0xAA)
    let otherCert = certData(0xBB)
    let profiles = [
      profile(type: "Distribution", bundleID: "net.example.app", teamID: "TEAM1", certs: [otherCert], expiration: 4_000_000_000),
      profile(type: "Distribution", bundleID: "net.example.app", teamID: "TEAM2", certs: [devCert], expiration: 4_000_000_000),
    ]
    #expect(XcodeCredentialImporter.selectProfile(
      from: profiles, bundleID: "net.example.app", kind: .distribution,
      certSHA1: sha1(devCert), teamID: "TEAM1"
    ) == nil)
  }

  @Test("prefers the later-expiring valid profile")
  func prefersLaterExpiration() {
    let devCert = certData(0xAA)
    let certSHA1 = sha1(devCert)
    let profiles = [
      profile(type: "Distribution", bundleID: "net.example.app", teamID: "TEAM1", certs: [devCert], expiration: 4_000_000_000, name: "early"),
      profile(type: "Distribution", bundleID: "net.example.app", teamID: "TEAM1", certs: [devCert], expiration: 4_100_000_000, name: "late"),
    ]
    let chosen = XcodeCredentialImporter.selectProfile(
      from: profiles, bundleID: "net.example.app", kind: .distribution,
      certSHA1: certSHA1, teamID: "TEAM1"
    )
    #expect(chosen?.name == "late")
  }
}

#endif
