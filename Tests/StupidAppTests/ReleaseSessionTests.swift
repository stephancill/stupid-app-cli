import ASCKit
import Foundation
import Testing

@testable import stupid_app

struct ReleaseSessionTests {
  @Test("a release session URL must be https, or http on localhost")
  func validatesURL() throws {
    #expect(try ReleaseSession.parse(nil) == nil)
    #expect(try ReleaseSession.parse("") == nil)
    let session = try #require(
      try ReleaseSession.parse("https://broker.example/v1/release/session/id/secret"))
    #expect(
      session.ascClient().baseURL.absoluteString
        == "https://broker.example/v1/release/session/id/secret/asc/v1")
    #expect(session.ascClient().jwt == nil)
    #expect(try ReleaseSession.parse("http://localhost:3000/v1/release/session/id/secret") != nil)
    for invalid in [
      "http://broker.example/v1/release/session/id/secret",
      "https://user@broker.example/v1/release/session/id/secret",
      "broker.example/v1/release/session/id/secret",
    ] {
      #expect(throws: ReleaseSession.Error.self) { try ReleaseSession.parse(invalid) }
    }
  }

  @Test("bundle ID profiles decode with their content")
  func decodesBundleIDProfiles() throws {
    let json = """
      {"data": [{"type": "profiles", "id": "P1", "attributes": {
        "name": "net.example.app AppStore", "profileType": "IOS_APP_STORE",
        "profileState": "ACTIVE", "expirationDate": "2027-08-12T12:18:57.000+00:00",
        "profileContent": "\(Data("profile".utf8).base64EncodedString())"}}]}
      """
    let profiles = try ASCOperations.decodeBundleIDProfiles(Data(json.utf8))
    #expect(profiles.count == 1)
    #expect(profiles[0].summary.id == "P1")
    #expect(profiles[0].summary.state == "ACTIVE")
    #expect(profiles[0].summary.expirationDate != nil)
    #expect(profiles[0].content == Data("profile".utf8))
  }
}
