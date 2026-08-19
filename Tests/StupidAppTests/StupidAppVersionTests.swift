import Testing

@testable import stupid_app

struct StupidAppVersionTests {
  @Test func productVersionIsSemanticVersion() {
    let parts = StupidApp.productVersion.split(separator: ".").map(String.init)
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { Int($0) != nil })
  }

  @Test func versionOutputPrefixesWithProductVersion() {
    let text = StupidApp.versionInformation(
      compilerVersion: "Swift version 6.2.1 (swiftlang-6.2.1.4.8 clang-1700.4.4.1)")
    #expect(text.hasPrefix("stupid-app \(StupidApp.productVersion)\n"))
  }

  @Test func versionOutputIncludesToolchainLine() {
    let text = StupidApp.versionInformation(
      compilerVersion: "Swift version 6.2.1 (swiftlang-6.2.1.4.8 clang-1700.4.4.1)")
    #expect(text.contains("Swift version 6.2.1"))
  }
}
