import ASCKit
import Foundation
import SigningKit

/// A release session on a signing broker, named by `STUPID_APP_RELEASE_SESSION`: an
/// approved session's base URL, which carries the session's secret. The broker holds the
/// App Store Connect key and the distribution private key, so a CI host can upload and
/// sign without either. Endpoints, relative to the base URL:
///
/// - `GET info`: `{ "teamId", "distributionCertificateId", "bundleIds" }`.
/// - `asc/v1/...`: App Store Connect, with the broker's authorization.
/// - `POST sign`: `{ "codeDirectory", "signedAttributes" }` (base64) to
///   `{ "signature" }` (base64), the RSA PKCS#1 v1.5 SHA-256 signature of the attributes.
struct ReleaseSession {
  static let environmentVariable = "STUPID_APP_RELEASE_SESSION"

  struct Info: Decodable {
    let teamId: String
    let distributionCertificateId: String
    let bundleIds: [String]
  }

  enum Error: Swift.Error, CustomStringConvertible {
    case invalidURL
    case malformedResponse(String)

    var description: String {
      switch self {
      case .invalidURL:
        return
          "\(ReleaseSession.environmentVariable) must be an https URL (http only for localhost). Copy the session URL the broker returned when the session was approved."
      case .malformedResponse(let endpoint):
        return "The release session returned a malformed \(endpoint) response."
      }
    }
  }

  let baseURL: URL

  /// The session named in the environment, or nil when none is set.
  static func fromEnvironment() throws -> ReleaseSession? {
    try parse(ProcessInfo.processInfo.environment[environmentVariable])
  }

  static func parse(_ value: String?) throws -> ReleaseSession? {
    guard let value, !value.isEmpty else { return nil }
    guard let url = URL(string: value), let host = url.host, url.user == nil,
      url.scheme == "https"
        || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    else { throw Error.invalidURL }
    return ReleaseSession(baseURL: url)
  }

  /// App Store Connect through the session. The broker adds the authorization.
  func ascClient() -> ASCClient {
    ASCClient(baseURL: baseURL.appendingPathComponent("asc/v1"), jwt: nil)
  }

  func info() throws -> Info {
    let response = try ASCClient(baseURL: baseURL, jwt: nil).request(method: .get, path: "info")
    guard let info = try? JSONDecoder().decode(Info.self, from: response.data) else {
      throw Error.malformedResponse("info")
    }
    return info
  }

  /// Signs through the session. `NativeCMS` verifies each signature against the
  /// certificate, so a wrong key or a tampered response fails the signing pass.
  func signer() -> CMSSigner {
    let client = ASCClient(baseURL: baseURL, jwt: nil)
    return CMSSigner { request in
      let response = try client.request(
        method: .post, path: "sign",
        body: [
          "codeDirectory": request.codeDirectory.base64EncodedString(),
          "signedAttributes": request.signedAttributes.base64EncodedString(),
        ])
      guard let json = response.json, let encoded = json["signature"] as? String,
        let signature = Data(base64Encoded: encoded)
      else { throw Error.malformedResponse("sign") }
      return signature
    }
  }
}
