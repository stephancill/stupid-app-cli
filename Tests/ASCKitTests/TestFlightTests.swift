import Foundation
import Testing
@testable import ASCKit

struct TestFlightTests {
  @Test("external review decision accepts App Store Connect's approval state")
  func reviewApproved() {
    #expect(ASCOperations.externalReviewDecision("APPROVED") == .approved)
  }

  @Test("external review decision keeps polling while in review")
  func reviewPolling() {
    #expect(ASCOperations.externalReviewDecision("WAITING_FOR_REVIEW") == .keepPolling)
    #expect(ASCOperations.externalReviewDecision("IN_REVIEW") == .keepPolling)
  }

  @Test("external review decision reports rejection")
  func reviewRejected() {
    #expect(ASCOperations.externalReviewDecision("REJECTED") == .rejected("REJECTED"))
  }

  @Test("external review decision fails on a missing or undocumented state instead of polling")
  func reviewUnexpected() {
    #expect(ASCOperations.externalReviewDecision(nil) == .unexpected(nil))
    #expect(ASCOperations.externalReviewDecision("BETA_APPROVED") == .unexpected("BETA_APPROVED"))
  }

  @Test("external beta readiness decision classifies readiness")
  func betaDecision() {
    #expect(ASCOperations.externalBetaDecision("IN_BETA_TESTING") == .ready)
    #expect(ASCOperations.externalBetaDecision("READY_FOR_BETA_TESTING") == .ready)
    #expect(ASCOperations.externalBetaDecision("PROCESSING") == .keepPolling)
    #expect(ASCOperations.externalBetaDecision("MISSING_EXPORT_COMPLIANCE") == .terminal("MISSING_EXPORT_COMPLIANCE"))
    #expect(ASCOperations.externalBetaDecision("BETA_REJECTED") == .terminal("BETA_REJECTED"))
    #expect(ASCOperations.externalBetaDecision(nil) == .terminal("missing externalBuildState"))
  }

  @Test("external beta readiness keeps polling while the build is in beta review")
  func betaDecisionDuringReview() {
    #expect(ASCOperations.externalBetaDecision("WAITING_FOR_BETA_REVIEW") == .keepPolling)
    #expect(ASCOperations.externalBetaDecision("IN_BETA_REVIEW") == .keepPolling)
    #expect(ASCOperations.externalBetaDecision("BETA_APPROVED") == .keepPolling)
  }

  @Test("decodes a beta app review submission's betaReviewState")
  func decodeSubmission() throws {
    // Shape of a live App Store Connect response (observed 2026-11-02).
    let json = """
    {
      "data": {
        "type": "betaAppReviewSubmissions",
        "id": "submission-1",
        "attributes": { "betaReviewState": "APPROVED", "submittedDate": null }
      }
    }
    """
    let submission = try ASCOperations.decodeBetaAppReviewSubmission(Data(json.utf8))
    #expect(submission.id == "submission-1")
    #expect(submission.state == "APPROVED")
  }

  @Test("decodes a created beta resource id")
  func decodeResourceID() throws {
    let json = #"{"data": {"type": "betaBuildLocalizations", "id": "loc-7"}}"#
    let id = try ASCOperations.decodeBetaResourceID(Data(json.utf8), resource: "test")
    #expect(id == "loc-7")
  }

  @Test("beta review submission relates only the build")
  func submissionBody() throws {
    let body = ASCOperations.betaAppReviewSubmissionBody(buildID: "build-1")
    let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains(#""build":{"data":{"id":"build-1","type":"builds"}}"#))
    #expect(!json.contains("betaGroup"))
  }
}
