import Foundation
import Testing

@testable import SwitchboardCore

private let changeRequest = "2026-11-14T08:53:58Z"
private let authorReply = "2026-11-14T18:07:49Z"

/// samplePR with the merge details that the poller read at its head commit.
private func detailedPR(gist: String? = "It caches flag reads per request.", additions: Int = 30, deletions: Int = 12)
  -> PullRequest
{
  var pr = samplePR(
    reviewDecision: .reviewRequired, checks: "SUCCESS", reviewRequests: ["alice"], reviewDecisionRead: true)
  pr.mergeDetails = MergeDetails(additions: additions, deletions: deletions, changedFiles: 3, gist: gist)
  return pr
}

/// A PR on which mariusandra requested changes and whose author, jzhu13, replied after that.
private func answeredPR() -> PullRequest {
  var pr = samplePR(
    reviewDecision: .changesRequested,
    verdicts: [
      Review(author: "mariusandra", state: "CHANGES_REQUESTED", submittedAt: changeRequest, commit: samplePRHead)
    ],
    reviews: [
      Review(author: "mariusandra", state: "CHANGES_REQUESTED", submittedAt: changeRequest),
      Review(author: "jzhu13", state: "COMMENTED", submittedAt: authorReply),
    ],
    checks: "SUCCESS", reviewDecisionRead: true)
  pr.author = "jzhu13"
  return pr
}

private func encoded(_ summary: PRSummary) throws -> [String: JSON] {
  try #require(try JSON(encoding: summary).object)
}

@Suite struct PRSummaryTests {
  // MARK: Merge details

  @Test func carriesTheGist() {
    #expect(PRSummary(detailedPR()).gist == "It caches flag reads per request.")
  }

  @Test func carriesTheAdditions() {
    #expect(PRSummary(detailedPR(additions: 30)).additions == 30)
  }

  @Test func carriesTheDeletions() {
    #expect(PRSummary(detailedPR(deletions: 12)).deletions == 12)
  }

  @Test func aBodyWithoutAGistLeavesTheGistNilButKeepsTheSize() {
    let summary = PRSummary(detailedPR(gist: nil, additions: 30, deletions: 12))

    #expect(summary.gist == nil)
    #expect(summary.additions == 30)
    #expect(summary.deletions == 12)
  }

  @Test func aPRWithoutMergeDetailsHasNoGistOrSize() {
    let summary = PRSummary(samplePR())

    #expect(summary.gist == nil)
    #expect(summary.additions == nil)
    #expect(summary.deletions == nil)
  }

  // MARK: Re-review

  @Test func carriesThePRsReReview() throws {
    let pr = answeredPR()
    let rereview = try #require(pr.rereview)

    #expect(PRSummary(pr).rereview == rereview)
  }

  @Test func aPRWithoutAReReviewHasNone() {
    #expect(PRSummary(samplePR()).rereview == nil)
  }

  // MARK: Wire format

  @Test func encodesTheGistAndSizeUnderTheirNames() throws {
    let json = try encoded(PRSummary(detailedPR()))

    #expect(json["gist"] == "It caches flag reads per request.")
    #expect(json["additions"] == 30)
    #expect(json["deletions"] == 12)
  }

  @Test func encodesTheReReviewAsReviewersAndRepliedAt() throws {
    let json = try encoded(PRSummary(answeredPR()))
    let repliedAt = try #require(Transcript.milliseconds(authorReply))

    #expect(json["rereview"] == ["reviewers": ["mariusandra"], "repliedAt": .number(Double(repliedAt))])
  }

  @Test func aSummaryWithoutTheNewFieldsHasNoKeysForThem() throws {
    let json = try encoded(PRSummary(samplePR()))

    for key in ["gist", "additions", "deletions", "rereview"] {
      #expect(json[key] == nil, "\(key)")
    }
  }

  @Test func roundTripsTheNewFields() throws {
    var pr = answeredPR()
    pr.mergeDetails = MergeDetails(additions: 30, deletions: 12, gist: "It caches flag reads per request.")
    let summary = PRSummary(pr)

    let decoded = try JSONCoding.convert(summary, to: PRSummary.self)

    #expect(decoded == summary)
  }

  /// An older sbd, local or on a remote host, sends none of the new keys.
  @Test func decodesJSONThatAnOlderSbdWroteWithoutTheNewFields() throws {
    var pr = answeredPR()
    pr.mergeDetails = MergeDetails(additions: 30, deletions: 12, gist: "It caches flag reads per request.")
    var object = try encoded(PRSummary(pr))
    for key in ["gist", "additions", "deletions", "rereview"] { object[key] = nil }

    let decoded = try JSONCoding.convert(JSON.object(object), to: PRSummary.self)

    #expect(decoded.gist == nil)
    #expect(decoded.additions == nil)
    #expect(decoded.deletions == nil)
    #expect(decoded.rereview == nil)
    #expect(decoded.number == 42)
  }

  @Test func decodesALiteralSummaryFromAnOlderSbd() throws {
    let text = """
      {"number": 42, "url": "https://github.com/acme/widgets/pull/42", "repo": "acme/widgets", "title": "",
       "state": "OPEN", "status": "Review required", "base": "main", "head": "feature",
       "reviewRequests": ["alice"], "reviewDecision": "REVIEW_REQUIRED", "approvers": []}
      """

    let decoded = try JSONCoding.decode(PRSummary.self, from: text)

    #expect(decoded.gist == nil)
    #expect(decoded.additions == nil)
    #expect(decoded.deletions == nil)
    #expect(decoded.rereview == nil)
  }
}
