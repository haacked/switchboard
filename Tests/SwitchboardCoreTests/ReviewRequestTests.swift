import Foundation
import Testing

@testable import SwitchboardCore

/// A PR that nobody reviewed and GitHub asks nobody to review: open, not a
/// draft, mergeable, its checks passed, and GitHub requires a review, so it
/// is not ready to merge.
private func unreviewedPR(
  draft: Bool = false, headSha: String = samplePRHead, base: String = "main", mergeable: Mergeable? = .mergeable,
  reviewDecision: ReviewDecision? = .reviewRequired, verdicts: [Review] = [], reviews: [Review] = [],
  checks: String? = "SUCCESS", mergedBase: Int? = nil, queue: TrunkQueueState? = nil,
  reviewRequests: [String]? = []
) -> PullRequest {
  var pr = samplePR(
    draft: draft, headSha: headSha, base: base, mergeable: mergeable, reviewDecision: reviewDecision,
    verdicts: verdicts, reviews: reviews, checks: checks, mergedBase: mergedBase, queue: queue,
    reviewRequests: reviewRequests)
  pr.title = "Fix"
  pr.trunkConfig = false
  return pr
}

func reviewRequestEvent(
  _ t: Int64, head: String = samplePRHead, _ result: String, reviewers: [String]? = nil, error: String? = nil
) -> Event {
  var fields: [String: JSON] = ["head": .string(head), "result": .string(result)]
  if let reviewers { fields["reviewers"] = .array(reviewers.map(JSON.string)) }
  if let error { fields["error"] = .string(error) }
  return event(ReviewRequestAttempt.event, t, fields)
}

private let now: Int64 = 10
private let readTheReply = Verdict(state: .needsYou, reason: "read its last reply and decide what's next")
private let card = Verdict(state: .needsYou, reason: "#42 is ready for review")

private func verdict(_ facts: SessionFacts) -> Verdict {
  Attention.evaluate(session(), facts, now: now)
}

/// The suites nest under one name, so `--filter ReviewRequestTests` runs them all.
@Suite struct ReviewRequestTests {}

extension ReviewRequestTests {
  @Suite struct Facts {
    @Test func reviewRequestEventSetsTheAttempt() {
      let f = facts([reviewRequestEvent(1, "requested", reviewers: ["alice", "@copilot"])])

      #expect(f.reviewRequest == ReviewRequestAttempt(head: samplePRHead, result: .requested, reviewers: ["alice", "@copilot"]))
    }

    @Test func attemptOnAnOlderHeadIsNotCurrent() throws {
      let f = try prFacts(unreviewedPR(headSha: "head2"), then: [reviewRequestEvent(5, head: "head1", "dismissed")])

      #expect(f.currentReviewRequest == nil)
    }
  }
}

extension ReviewRequestTests {
  @Suite struct Card {
    @Test func unreviewedPRWithNobodyAskedShowsTheCard() throws {
      let f = try prFacts(unreviewedPR())

      let v = verdict(f)

      #expect(v == card)
      #expect(v.kind == .action)
      #expect(
        v.options == [
          TriageOption(label: "Request review", action: .requestReview, recommended: true),
          TriageOption(label: "Dismiss", action: .dismissReview),
        ])
    }

    @Test func cardShowsThePRTitleAndChecks() throws {
      let f = try prFacts(unreviewedPR())

      let item = try #require(Triage.item(f, verdict(f)))

      #expect(item.title == "#42 is ready for review")
      #expect(item.summary == "#42 Fix\nChecks success. Nobody has reviewed it, and GitHub asks nobody to.")
      #expect(item.source == .rule)
    }

    @Test(arguments: [
      ("checks pending", unreviewedPR(checks: "PENDING"), "Checks pending"),
      ("no checks", unreviewedPR(checks: nil), "No checks"),
      ("no review required", unreviewedPR(reviewDecision: nil, checks: "PENDING"), "Checks pending"),
      (
        "a pending review of the user's own", unreviewedPR(reviews: [sampleVerdict("me", "PENDING")]),
        "Checks success"
      ),
    ])
    func prThatStillNeedsAReviewShowsTheCard(_ label: String, _ pr: PullRequest, _ checks: String) throws {
      let f = try prFacts(pr)

      #expect(verdict(f) == card, "\(label)")
      #expect(Triage.item(f, verdict(f))?.summary.contains(checks) == true, "\(label)")
    }

    @Test(arguments: [
      ("draft", unreviewedPR(draft: true)),
      ("review requests not read", unreviewedPR(reviewRequests: nil)),
      ("a reviewer requested", unreviewedPR(reviewRequests: ["ann"])),
      ("a team requested", unreviewedPR(reviewRequests: ["widgets-team"])),
      ("a comment review", unreviewedPR(reviews: [sampleVerdict("bob", "COMMENTED")])),
      ("a bot's comment review", unreviewedPR(reviews: [sampleVerdict("copilot-pull-request-reviewer", "COMMENTED")])),
      ("a dismissed review", unreviewedPR(reviews: [sampleVerdict("bob", "DISMISSED")])),
      ("approved", unreviewedPR(reviewDecision: .approved, verdicts: [sampleVerdict("ann", "APPROVED")])),
      ("changes requested", unreviewedPR(reviewDecision: .changesRequested)),
      ("checks failed", unreviewedPR(checks: "FAILURE")),
      ("checks errored", unreviewedPR(checks: "ERROR")),
      ("conflicting", unreviewedPR(mergeable: .conflicting)),
      ("merged base", unreviewedPR(base: "haacked/parent", mergedBase: 41)),
      ("in Trunk's queue", unreviewedPR(queue: .testing)),
      ("submitted to Trunk", unreviewedPR(queue: .submitted)),
    ])
    func prThatHasAReviewOrAnotherProblemShowsNoCard(_ label: String, _ pr: PullRequest) throws {
      let f = try prFacts(pr)

      #expect(verdict(f) != card, "\(label)")
      #expect(!verdict(f).options.contains { $0.action == .requestReview }, "\(label)")
    }

    @Test func prThatCanMergeWithoutAReviewIsReadyToMerge() throws {
      let f = try prFacts(unreviewedPR(reviewDecision: nil))

      #expect(verdict(f).state == .readyToMerge)
    }

    @Test func prThatADependencyHoldsWaitsOnIt() throws {
      let dependency = Dependency(via: .body, repo: "acme/widgets", number: 41, state: .open)
      let f = try prFacts(unreviewedPR(), then: [try dependenciesEvent(3, [dependency])])

      #expect(verdict(f) != card)
    }

    @Test(arguments: ["Which base should it target?", "Want me to request a review?"])
    func replyThatAsksOrOffersKeepsItsVerdict(_ reply: String) throws {
      let f = try prFacts(unreviewedPR(), reply: reply)

      #expect(verdict(f) != card)
      #expect(verdict(f).source == .reply)
    }

    @Test func runningTurnShowsNoCard() throws {
      let f = try prFacts(unreviewedPR(), then: [event("UserPromptSubmit", 4, ["prompt": "keep going"])])

      #expect(verdict(f).state == .working)
    }

    @Test func runningSubagentsShowNoCard() throws {
      let f = try prFacts(unreviewedPR(), then: [event("SubagentStart", 4, ["agent_id": "a1"])])

      #expect(verdict(f) == Verdict(state: .readyForReview, reason: "#42 Fix; review required, checks success; waiting on 1 subagent"))
    }
  }
}

extension ReviewRequestTests {
  @Suite struct Attempts {
    @Test func dismissalAtTheHeadHidesTheCard() throws {
      let f = try prFacts(unreviewedPR(), then: [reviewRequestEvent(5, "dismissed")])

      #expect(verdict(f) == readTheReply)
    }

    @Test func newCommitAfterADismissalShowsTheCardAgain() throws {
      let f = try prFacts(
        unreviewedPR(), then: [reviewRequestEvent(5, "dismissed"), try prEvent(6, unreviewedPR(headSha: "head2"))])

      #expect(verdict(f) == card)
    }

    @Test func requestAtTheHeadMovesTheSessionToReadyForReview() throws {
      let f = try prFacts(unreviewedPR(), then: [reviewRequestEvent(5, "requested", reviewers: ["alice", "@copilot"])])

      #expect(
        verdict(f)
          == Verdict(
            state: .readyForReview, reason: "#42 Fix; review requested from alice and @copilot, checks success"))
    }

    @Test func requestedSessionIsNotInTheInbox() throws {
      let f = try prFacts(unreviewedPR(), then: [reviewRequestEvent(5, "requested", reviewers: ["alice"])])

      #expect(Triage.item(f, verdict(f)) == nil)
    }

    @Test func gitHubListingTheReviewerGivesTheSameVerdict() throws {
      let f = try prFacts(
        unreviewedPR(),
        then: [
          reviewRequestEvent(5, "requested", reviewers: ["alice"]), try prEvent(6, unreviewedPR(reviewRequests: ["alice"])),
        ])

      #expect(verdict(f) == Verdict(state: .readyForReview, reason: "#42 Fix; review requested from alice, checks success"))
    }

    @Test func newCommitAfterARequestShowsTheCardAgainWhenNobodyIsAsked() throws {
      let f = try prFacts(
        unreviewedPR(),
        then: [reviewRequestEvent(5, "requested", reviewers: ["alice"]), try prEvent(6, unreviewedPR(headSha: "head2"))])

      #expect(verdict(f) == card)
    }

    @Test func failedRequestKeepsTheCardWithGhsError() throws {
      let f = try prFacts(unreviewedPR(), then: [reviewRequestEvent(5, "failed", error: "could not resolve user")])

      let v = verdict(f)

      #expect(v == card)
      #expect(v.callouts == [Callout(kind: .warning, title: "The last review request failed", body: "could not resolve user")])
      #expect(f.reviewRequestError == "could not resolve user")
    }
  }
}

extension ReviewRequestTests {
  @Suite struct Actions {
    @Test func reviewActionsSayWhatAClickDoes() {
      #expect(
        TriageOption(label: "Request review", action: .requestReview).effect
          == "Requests a review from the reviewers you pick")
      #expect(
        TriageOption(label: "Dismiss", action: .dismissReview).effect
          == "Hides the review card until the PR gets a new commit")
    }

    @Test func sessionCardsCannotNameTheReviewActions() {
      #expect(!TriageAction.writable.contains(.requestReview))
      #expect(!TriageAction.writable.contains(.dismissReview))
    }

    @Test(arguments: [TriageAction.merge, .dismiss, .requestReview, .dismissReview])
    func prActionsNeedTheUsersClick(_ action: TriageAction) {
      #expect(action.needsClick)
    }

    @Test(arguments: [TriageAction.send, .reply, .wait, .done])
    func sessionActionsDoNotNeedAClick(_ action: TriageAction) {
      #expect(!action.needsClick)
    }
  }
}

extension ReviewRequestTests {
  @Suite struct Suggestions {
    static func response(author: String = "me", _ suggested: [(String, isAuthor: Bool, isCommenter: Bool)]) -> JSON {
      let nodes = suggested.map { login, isAuthor, isCommenter -> JSON in
        ["isAuthor": .bool(isAuthor), "isCommenter": .bool(isCommenter), "reviewer": ["login": .string(login)]]
      }
      return [
        "data": ["repository": ["pullRequest": ["author": ["login": .string(author)], "suggestedReviewers": .array(nodes)]]]
      ]
    }

    @Test func gitHubsSuggestionsComeFirstAndCopilotLast() throws {
      let json = Self.response([("ann", true, false), ("bob", false, true), ("cy", true, true)])

      let got = try ReviewRequests.suggestions(from: json)

      #expect(
        got == [
          ReviewerSuggestion(login: "ann", reason: "committed to the changed files"),
          ReviewerSuggestion(login: "bob", reason: "reviewed the changed files"),
          ReviewerSuggestion(login: "cy", reason: "committed to and reviewed the changed files"),
          ReviewerSuggestion(login: "@copilot", reason: "GitHub Copilot's code review"),
        ])
    }

    @Test func prAuthorIsNotSuggested() throws {
      let json = Self.response(author: "ann", [("ann", true, false), ("bob", false, true)])

      let got = try ReviewRequests.suggestions(from: json)

      #expect(got.map(\.login) == ["bob", "@copilot"])
    }

    @Test func noSuggestionsLeavesCopilot() throws {
      let got = try ReviewRequests.suggestions(from: Self.response([]))

      #expect(got.map(\.login) == ["@copilot"])
    }

    @Test func responseWithoutAPRThrows() {
      #expect(throws: (any Error).self) { try ReviewRequests.suggestions(from: ["data": ["repository": .null]]) }
    }

    @Test(arguments: ["alice", "a-1", "acme/widgets-team", "acme/team.name_2", "@copilot"])
    func reviewerLoginsAndTeamsAreAccepted(_ login: String) {
      #expect(ReviewRequests.isValidReviewer(login))
    }

    @Test(arguments: ["", "-alice", "--repo", "a b", "a,b", "@alice", "acme/", "/team", "a/b/c", "al\nice", "alice\n"])
    func otherReviewerTextIsRefused(_ login: String) {
      #expect(!ReviewRequests.isValidReviewer(login))
    }

    @Test func reviewerTextSplitsOnCommasAndSpaces() {
      #expect(ReviewRequests.reviewers(in: " alice, @copilot  bob,alice") == ["alice", "@copilot", "bob"])
    }
  }
}
