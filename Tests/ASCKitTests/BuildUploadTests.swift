import Foundation
import Testing
@testable import ASCKit

/// Unit tests for Build Upload model decoding, exact-build matching, checksum
/// verification, and release-manifest serialization. Uses only synthetic fixtures;
/// no credentials or live API calls.
struct BuildUploadTests {
    // MARK: - Decoding

    @Test("decodes a Build Upload with nested state")
    func decodeBuildUpload() throws {
        let json = """
        {
          "data": {
            "type": "buildUploads",
            "id": "upload-1",
            "attributes": {
              "cfBundleShortVersionString": "1.0.0",
              "cfBundleVersion": "42",
              "platform": "IOS",
              "createdDate": "2026-01-01T00:00:00Z",
              "state": {
                "state": "AWAITING_UPLOAD",
                "errors": []
              }
            }
          },
          "links": {}
        }
        """
        let upload = try ASCOperations.decodeBuildUpload(Data(json.utf8))
        #expect(upload.id == "upload-1")
        #expect(upload.cfBundleShortVersionString == "1.0.0")
        #expect(upload.cfBundleVersion == "42")
        #expect(upload.state == "AWAITING_UPLOAD")
        #expect(upload.stateErrors.isEmpty)
    }

    @Test("decodes a failed Build Upload with error codes")
    func decodeFailedBuildUpload() throws {
        let json = """
        {
          "data": {
            "type": "buildUploads",
            "id": "upload-2",
            "attributes": {
              "state": {
                "state": "FAILED",
                "errors": [{"code": "90062"}, {"code": "90186"}]
              }
            }
          },
          "links": {}
        }
        """
        let upload = try ASCOperations.decodeBuildUpload(Data(json.utf8))
        #expect(upload.state == "FAILED")
        #expect(upload.stateErrors == ["90062", "90186"])
    }

    @Test("decodes a Build Upload File with upload operations")
    func decodeBuildUploadFile() throws {
        let json = """
        {
          "data": {
            "type": "buildUploadFiles",
            "id": "file-1",
            "attributes": {
              "fileName": "App.ipa",
              "fileSize": 100,
              "assetType": "ASSET",
              "uti": "com.apple.ipa",
              "uploadOperations": [
                {
                  "method": "PUT",
                  "url": "https://upload.example.test/part-1",
                  "length": 100,
                  "offset": 0,
                  "requestHeaders": [
                    {"name": "Content-Type", "value": "application/octet-stream"}
                  ],
                  "expiration": "2026-01-02T00:00:00Z",
                  "partNumber": 1,
                  "entityTag": "etag-1"
                }
              ]
            }
          },
          "links": {}
        }
        """
        let file = try ASCOperations.decodeBuildUploadFile(Data(json.utf8))
        #expect(file.id == "file-1")
        #expect(file.fileName == "App.ipa")
        #expect(file.fileSize == 100)
        #expect(file.uploadOperations.count == 1)
        let operation = file.uploadOperations[0]
        #expect(operation.method == "PUT")
        #expect(operation.offset == 0)
        #expect(operation.length == 100)
        #expect(operation.requestHeaders == ["Content-Type": "application/octet-stream"])
        #expect(operation.partNumber == 1)
        #expect(operation.entityTag == "etag-1")
    }

    // MARK: - Exact build matching

    @Test("matches the exact build by preReleaseVersion marketing version")
    func matchExactBuild() throws {
        let json = """
        {
          "data": [
            {
              "type": "builds",
              "id": "build-123",
              "attributes": {"version": "42", "processingState": "VALID", "uploadedDate": "2026-01-01T00:00:00Z"},
              "relationships": {"preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": "prv-1"}}}
            },
            {
              "type": "builds",
              "id": "build-999",
              "attributes": {"version": "42", "processingState": "VALID"},
              "relationships": {"preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": "prv-2"}}}
            }
          ],
          "included": [
            {"type": "preReleaseVersions", "id": "prv-1", "attributes": {"version": "1.0.0", "platform": "IOS"}},
            {"type": "preReleaseVersions", "id": "prv-2", "attributes": {"version": "2.0.0", "platform": "IOS"}}
          ]
        }
        """
        let envelope = try JSONDecoder().decode(BuildListEnvelope.self, from: Data(json.utf8))
        let matched = ASCOperations.matchBuild(
            from: envelope.data,
            included: envelope.included ?? [],
            version: "1.0.0",
            buildNumber: "42"
        )
        #expect(matched?.id == "build-123")
        #expect(matched?.processingState == "VALID")
    }

    @Test("returns nil when marketing version does not match")
    func matchExactBuildNoMatch() throws {
        let json = """
        {
          "data": [
            {
              "type": "builds",
              "id": "build-123",
              "attributes": {"version": "42"},
              "relationships": {"preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": "prv-1"}}}
            }
          ],
          "included": [
            {"type": "preReleaseVersions", "id": "prv-1", "attributes": {"version": "9.9.9"}}
          ]
        }
        """
        let envelope = try JSONDecoder().decode(BuildListEnvelope.self, from: Data(json.utf8))
        let matched = ASCOperations.matchBuild(
            from: envelope.data,
            included: envelope.included ?? [],
            version: "1.0.0",
            buildNumber: "42"
        )
        #expect(matched == nil)
    }

    @Test("returns nil when the build is not visible yet")
    func matchExactBuildNotVisible() throws {
        let envelope = BuildListEnvelope(data: [], included: nil)
        let matched = ASCOperations.matchBuild(from: envelope.data, included: [], version: "1.0.0", buildNumber: "42")
        #expect(matched == nil)
    }

    // MARK: - Checksums

    @Test("computes MD5 file and composite checksums")
    func computesChecksums() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-checksum-\(UUID().uuidString).bin")
        try Data("hello world".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = ASCSourceFileChecksums(
            file: ASCChecksumValue(hash: "5eb63bbbe01eeed093cb22bb8f5acdc3", algorithm: "MD5"),
            composite: ASCChecksumValue(hash: "5eb63bbbe01eeed093cb22bb8f5acdc3", algorithm: "MD5")
        )
        let checksums = try BuildUploader.computeAndVerifyChecksums(fileURL: url, expected: expected)
        // MD5 of "hello world" is 5eb63bbbe01eeed093cb22bb8f5acdc3
        #expect(checksums?.file?.hash == "5eb63bbbe01eeed093cb22bb8f5acdc3")
        #expect(checksums?.file?.algorithm == "MD5")
        #expect(checksums?.composite?.hash == "5eb63bbbe01eeed093cb22bb8f5acdc3")
    }

    @Test("verifies a matching declared checksum")
    func verifiesDeclaredChecksum() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-checksum-\(UUID().uuidString).bin")
        try Data("hello world".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = ASCSourceFileChecksums(
            file: ASCChecksumValue(hash: "5eb63bbbe01eeed093cb22bb8f5acdc3", algorithm: "MD5"),
            composite: ASCChecksumValue(hash: "5eb63bbbe01eeed093cb22bb8f5acdc3", algorithm: "MD5")
        )
        let checksums = try BuildUploader.computeAndVerifyChecksums(fileURL: url, expected: expected)
        #expect(checksums?.file?.hash == expected.file?.hash)
        #expect(checksums?.composite?.hash == expected.composite?.hash)
    }

    @Test("rejects a checksum mismatch loudly")
    func rejectsChecksumMismatch() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-checksum-\(UUID().uuidString).bin")
        try! Data("hello world".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let wrong = ASCSourceFileChecksums(
            file: ASCChecksumValue(hash: "deadbeef", algorithm: "MD5"),
            composite: ASCChecksumValue(hash: "5eb63bbbe01eeed093cb22bb8f5acdc3", algorithm: "MD5")
        )
        #expect(throws: BuildUploader.Error.self) {
            try BuildUploader.computeAndVerifyChecksums(fileURL: url, expected: wrong)
        }
    }

    @Test("supports a SHA-256 declared file checksum")
    func computesSHA256FileChecksum() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-checksum-\(UUID().uuidString).bin")
        try Data("hello world".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // SHA-256 of "hello world" is 2ef7bde608ce5404e97d5f042f95f89f1c232871.
        let expected = ASCSourceFileChecksums(
            file: ASCChecksumValue(hash: "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9", algorithm: "SHA_256"),
            composite: ASCChecksumValue(hash: "5eb63bbbe01eeed093cb22bb8f5acdc3", algorithm: "MD5")
        )
        let checksums = try BuildUploader.computeAndVerifyChecksums(fileURL: url, expected: expected)
        #expect(checksums?.file?.algorithm == "SHA_256")
    }

    @Test("returns nil checksums when the server declares none")
    func returnsNilWhenNoChecksumsDeclared() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-checksum-\(UUID().uuidString).bin")
        try Data("hello world".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let checksums = try BuildUploader.computeAndVerifyChecksums(fileURL: url, expected: ASCSourceFileChecksums())
        #expect(checksums == nil)
    }

    // MARK: - Release manifest

    @Test("release manifest round-trips and is public-safe")
    func releaseManifestRoundTrip() throws {
        let manifest = ReleaseManifest(
            appBundleId: "net.example.acceptance-app",
            marketingVersion: "1.0.0",
            buildNumber: "42",
            ipaPath: ".release/AcceptanceApp.ipa",
            ipaSha256: "abc123",
            buildUploadId: "upload-1",
            buildId: "build-1",
            uploadState: "COMPLETE",
            processingState: "VALID",
            internalBetaState: "IN_BETA_TESTING"
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stupid-app-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try manifest.write(to: url)

        let decoded = try JSONDecoder().decode(ReleaseManifest.self, from: Data(contentsOf: url))
        #expect(decoded == manifest)
        let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(raw.contains("net.example.acceptance-app"))
        #expect(!raw.contains("apiKey"))
        #expect(!raw.contains("issuer"))
        #expect(!raw.contains("secret"))
    }

    // MARK: - Latest build number

    @Test("decodes the newest uploaded build number")
    func decodeLatestBuildNumber() throws {
        let json = """
        {
          "data": [
            { "id": "build-5", "attributes": { "version": "104" } }
          ]
        }
        """
        let number = try ASCOperations.decodeLatestBuildNumber(Data(json.utf8))
        #expect(number == "104")
    }

    @Test("returns nil when no builds exist")
    func decodeLatestBuildNumberEmpty() throws {
        let number = try ASCOperations.decodeLatestBuildNumber(Data("{\"data\": []}".utf8))
        #expect(number == nil)
    }

    @Test("rejects a malformed latest-build response")
    func decodeLatestBuildNumberMalformed() {
        #expect(throws: ASCError.self) {
            _ = try ASCOperations.decodeLatestBuildNumber(Data("not json".utf8))
        }
    }

    // MARK: - Beta readiness state transitions

    @Test("beta state reaches readiness at READY_FOR_BETA_TESTING")
    func betaReadyState() throws {
        let decision = try BuildUploader.betaReadinessDecision("READY_FOR_BETA_TESTING")
        #expect(decision == .ready)
    }

    @Test("beta state reaches readiness at IN_BETA_TESTING")
    func betaInTestingState() throws {
        let decision = try BuildUploader.betaReadinessDecision("IN_BETA_TESTING")
        #expect(decision == .ready)
    }

    @Test("beta state keeps polling while processing")
    func betaProcessingState() throws {
        let decision = try BuildUploader.betaReadinessDecision("PROCESSING")
        #expect(decision == .keepPolling)
    }

    @Test("beta state keeps polling while nil")
    func betaNilState() throws {
        let decision = try BuildUploader.betaReadinessDecision(nil)
        #expect(decision == .keepPolling)
    }

    @Test("beta state fails loudly on terminal failures")
    func betaFailureStates() {
        for state in ["PROCESSING_EXCEPTION", "MISSING_EXPORT_COMPLIANCE", "EXPIRED"] {
            #expect(throws: BuildUploader.Error.self) {
                _ = try BuildUploader.betaReadinessDecision(state)
            }
        }
    }
}
