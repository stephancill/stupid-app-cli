import Foundation
import Testing
@testable import ASCKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `buildID(for:)` resolves a manifest written by an upload without `--wait`, which
/// records no build id, against a stubbed App Store Connect. No credentials or live calls.
@Suite(.serialized)
struct ManifestBuildTests {
    private let operations = ASCOperations(client: ASCClient(
        baseURL: URL(string: "https://asc.stub.invalid/v1")!,
        jwt: { "stub-jwt" }
    ))

    init() {
        URLProtocol.registerClass(StubASC.self)
    }

    private func manifest(buildId: String?) -> ReleaseManifest {
        ReleaseManifest(
            appBundleId: "net.example.App",
            marketingVersion: "1.0.1",
            buildNumber: "181",
            ipaPath: ".release/App.ipa",
            ipaSha256: "00",
            buildUploadId: "upload-1",
            buildId: buildId
        )
    }

    @Test("uses the recorded build id without asking App Store Connect")
    func recordedBuild() throws {
        StubASC.responses = [:]
        #expect(try operations.buildID(for: manifest(buildId: "build-recorded")) == "build-recorded")
        #expect(StubASC.requestedPaths.isEmpty)
    }

    @Test("finds the build an upload without --wait did not record")
    func lookedUpBuild() throws {
        StubASC.responses = [
            "/v1/apps": #"{"data":[{"id":"app-1","attributes":{"bundleId":"net.example.App"}}]}"#,
            "/v1/builds": #"""
            {"data":[{"type":"builds","id":"build-181","attributes":{"version":"181","processingState":"VALID"},
              "relationships":{"preReleaseVersion":{"data":{"type":"preReleaseVersions","id":"prv-1"}}}}],
             "included":[{"type":"preReleaseVersions","id":"prv-1","attributes":{"version":"1.0.1"}}]}
            """#,
        ]
        #expect(try operations.buildID(for: manifest(buildId: nil)) == "build-181")
    }

    @Test("returns nil while App Store Connect has not created the build")
    func buildNotVisibleYet() throws {
        StubASC.responses = [
            "/v1/apps": #"{"data":[{"id":"app-1","attributes":{"bundleId":"net.example.App"}}]}"#,
            "/v1/builds": #"{"data":[],"included":[]}"#,
        ]
        #expect(try operations.buildID(for: manifest(buildId: nil)) == nil)
    }
}

/// Answers requests to the stub host from `responses`, keyed by path.
final class StubASC: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: String] = [:] {
        didSet { requestedPaths = [] }
    }
    nonisolated(unsafe) static var requestedPaths: [String] = []
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "asc.stub.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.requestedPaths.append(path)
        let body = Self.responses[path]
        let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
