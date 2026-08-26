import Foundation
import Testing

@testable import stupid_app

@Suite("Simulator entitlements")
struct SimulatorEntitlementsTests {
  @Test("drops keychain-access-groups for team-less simulator signing")
  func dropsKeychainAccessGroups() {
    let override = RunCommand.SimulatorEntitlements.sanitize([
      "keychain-access-groups": ["$(AppIdentifierPrefix)com.example"],
      "com.apple.security.application-groups": ["group.com.example"],
    ])

    #expect(override["keychain-access-groups"] == nil)
    #expect((override["com.apple.security.application-groups"] as? [String])?.first
      == "group.com.example")
  }

  @Test("drops profile-gated autofill-credential-provider")
  func dropsProfileGatedAutofill() {
    let override = RunCommand.SimulatorEntitlements.sanitize([
      "com.apple.developer.authentication-services.autofill-credential-provider": true,
      "com.apple.security.application-groups": ["group.com.example"],
    ])

    #expect(override["com.apple.developer.authentication-services.autofill-credential-provider"]
      == nil)
    #expect(override["com.apple.security.application-groups"] != nil)
  }

  @Test("removes AppIdentifierPrefix from preserved app groups")
  func removesAppIdentifierPrefix() {
    let override = RunCommand.SimulatorEntitlements.sanitize([
      "com.apple.security.application-groups": ["$(AppIdentifierPrefix)group.com.example"],
    ])

    #expect(
      (override["com.apple.security.application-groups"] as? [String]) == ["group.com.example"])
  }

  @Test("preserves unrelated entitlements")
  func preservesUnrelated() {
    let override = RunCommand.SimulatorEntitlements.sanitize([
      "com.apple.security.application-groups": ["group.com.example"],
      "some.custom.entitlement": "value",
    ])

    #expect(override["some.custom.entitlement"] as? String == "value")
  }

  @Test("is a no-op for an empty source dictionary")
  func emptySource() {
    let override = RunCommand.SimulatorEntitlements.sanitize([:])

    #expect(override.isEmpty)
  }
}