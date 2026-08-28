import Foundation
import Testing
@testable import ASCKit

struct TestFlightTests {
  @Test("external review decision accepts approval states")
  func reviewApproved() {
    #expect(ASCOperations.externalReviewDecision("BETA_APPROVED") == .approved)
    #expect(ASCOperations.externalReviewDecision("IN_BETA_TESTING") == .approved)
  }

  @Test("external review decision keeps polling transient states")
  func reviewPolling() {
    #expect(ASCOperations.externalReviewDecision("WAITING_FOR_REVIEW") == .keepPolling)
    #expect(ASCOperations.externalReviewDecision("IN_REVIEW") == .keepPolling)
    #expect(ASCOperations.externalReviewDecision(nil) == .keepPolling)
  }

  @Test("external review decision rejects terminal states")
  func reviewRejected() {
    #expect(ASCOperations.externalReviewDecision("BETA_REJECTED") == .rejected("BETA_REJECTED"))
    #expect(ASCOperations.externalReviewDecision("PLAN_REQUIRED") == .rejected("PLAN_REQUIRED"))
  }

  @Test("external beta readiness decision classifies readiness")
  func betaDecision() {
    #expect(ASCOperations.externalBetaDecision("IN_BETA_TESTING") == .ready)
    #expect(ASCOperations.externalBetaDecision("READY_FOR_BETA_TESTING") == .ready)
    #expect(ASCOperations.externalBetaDecision("PROCESSING") == .keepPolling)
    #expect(ASCOperations.externalBetaDecision(nil) == .keepPolling)
    #expect(ASCOperations.externalBetaDecision("MISSING_EXPORT_COMPLIANCE") == .terminal("MISSING_EXPORT_COMPLIANCE"))
  }

  @Test("decodes a beta app review submission resource")
  func decodeSubmission() throws {
    let json = """
    {
      "data": {
        "type": "betaAppReviewSubmissions",
        "id": "submission-1",
        "attributes": { "submissionState": "IN_REVIEW" }
      }
    }
    """
    let submission = try ASCOperations.decodeBetaAppReviewSubmission(Data(json.utf8))
    #expect(submission.id == "submission-1")
    #expect(submission.state == "IN_REVIEW")
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
