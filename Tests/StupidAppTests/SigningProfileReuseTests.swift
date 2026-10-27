import Testing

@testable import stupid_app

@Suite("Signing profile reuse")
struct SigningProfileReuseTests {
  @Test("matches the base profile name and its numbered replacements only")
  func matchesReplacementNames() {
    let base = "net.example.app AppStore"
    #expect(SigningSetupCommand.isProfileName(base, base: base))
    #expect(SigningSetupCommand.isProfileName("\(base) 2", base: base))
    #expect(SigningSetupCommand.isProfileName("\(base) 13", base: base))
    #expect(!SigningSetupCommand.isProfileName("\(base) old", base: base))
    #expect(!SigningSetupCommand.isProfileName("\(base)2", base: base))
    #expect(!SigningSetupCommand.isProfileName("net.example.app.widget AppStore", base: base))
  }
}
