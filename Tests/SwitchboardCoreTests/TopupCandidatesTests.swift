import Foundation
import Testing

@testable import SwitchboardCore

private let repo = "haacked/switchboard"
private let group = "g49tj7"
private let viewer = "haacked"
private let team = IssueTeam(people: ["alice"])

private func issue(_ number: Int, author: String? = viewer, title: String? = nil) -> InboxIssue {
  InboxIssue(
    repo: repo, number: number, title: title ?? "Issue \(number)", url: "https://github.com/\(repo)/issues/\(number)",
    body: "Body of \(number)", author: author, createdAt: "2026-11-01T00:00:00Z", updatedAt: "2026-11-02T00:00:00Z")
}

private func sessionRow(
  repository: String? = repo, branch: String? = nil, prNumber: Int? = nil, issue link: IssueRef? = nil,
  closesIssues: [IssueRef]? = nil
) -> TopupCandidates.SessionRow {
  TopupCandidates.SessionRow(
    repository: repository, branch: branch, prNumber: prNumber, issue: link, closesIssues: closesIssues)
}

private func openPR(_ number: Int, head: String = "haacked/some-change", closes: [IssueRef] = [])
  -> TopupCandidates.OpenPR
{
  TopupCandidates.OpenPR(number: number, headRefName: head, closes: closes)
}

/// A follow-up that waits to start.
private func waitingFollowup(
  _ id: String, repository: String? = repo, group followupGroup: String? = group, started: Int64? = nil,
  trigger: Followup.Trigger = .manual, ready: Int64? = nil, done: Bool = false
) -> Session {
  var s = Session(id: id, name: "follow-up \(id)", cwd: "", claudeSessionId: "", created: 1)
  var f = Followup(prompt: "Do the thing \(id)", repository: repository, trigger: trigger)
  f.started = started
  f.ready = ready
  s.followup = f
  s.group = followupGroup
  s.done = done
  return s
}

private let mergeTrigger = Followup.Trigger.merge(Wait.PullRequest(repository: repo, number: 40))

private func build(
  issues: [InboxIssue] = [], openPRs: [TopupCandidates.OpenPR] = [], sessions: [TopupCandidates.SessionRow] = [],
  followups: [Session] = [], viewer buildViewer: String? = viewer, team buildTeam: IssueTeam = team
) -> TopupCandidates {
  TopupCandidates.build(
    repo: repo, group: group, issues: issues, openPRs: openPRs, sessions: sessions, followups: followups,
    viewer: buildViewer, team: buildTeam)
}

private func refs(_ result: TopupCandidates) -> [String] { result.candidates.map(\.ref) }

/// The suites nest under one name, so `--filter TopupCandidatesTests` runs them all.
@Suite struct TopupCandidatesTests {}

// MARK: - Issues

extension TopupCandidatesTests {
  @Suite struct IssueCandidates {
    @Test func anUncoveredTrustedIssueIsACandidate() {
      #expect(refs(build(issues: [issue(12)])) == ["#12"])
    }

    @Test func eachUncoveredTrustedIssueIsACandidate() {
      #expect(Set(refs(build(issues: [issue(12), issue(13), issue(14)]))) == ["#12", "#13", "#14"])
    }

    /// A ref names an issue by number alone, so an issue of another repository can't be a candidate.
    @Test func anIssueOfAnotherRepositoryIsNotACandidate() {
      var other = issue(12)
      other.repo = "haacked/dotfiles"

      #expect(refs(build(issues: [other])).isEmpty)
    }

    @Test func anIssueOfTheRepositoryWrittenInAnotherCaseIsACandidate() {
      var same = issue(12)
      same.repo = "Haacked/Switchboard"

      #expect(refs(build(issues: [same])) == ["#12"])
    }

    @Test func noIssuesAndNoFollowupsGiveNoCandidates() {
      let result = build()

      #expect(result.candidates.isEmpty)
      #expect(result.skips.isEmpty)
    }
  }
}

// MARK: - Coverage

extension TopupCandidatesTests {
  @Suite struct Coverage {
    @Test func anIssueCoveredByASessionsBranchIsLeftOut() {
      let result = build(issues: [issue(12), issue(13)], sessions: [sessionRow(branch: "haacked/12-fix-the-thing")])

      #expect(refs(result) == ["#13"])
    }

    @Test func anIssueCoveredByABranchWithoutAPrefixIsLeftOut() {
      #expect(refs(build(issues: [issue(12)], sessions: [sessionRow(branch: "12-fix-the-thing")])).isEmpty)
    }

    /// A branch number names an issue in the session's own repository only.
    @Test func aBranchInAnotherRepositoryDoesNotCoverTheIssue() {
      let result = build(
        issues: [issue(12)], sessions: [sessionRow(repository: "haacked/dotfiles", branch: "haacked/12-fix-the-thing")])

      #expect(refs(result) == ["#12"])
    }

    /// A session whose repository sbd hasn't read may work in the gate's repository.
    @Test func aBranchWithNoRepositoryCoversTheIssue() {
      let result = build(
        issues: [issue(12)], sessions: [sessionRow(repository: nil, branch: "haacked/12-fix-the-thing")])

      #expect(refs(result).isEmpty)
    }

    @Test func anIssueLinkWithoutARepositoryOnASessionWithNoRepositoryCoversTheIssue() {
      let result = build(
        issues: [issue(12)], sessions: [sessionRow(repository: nil, issue: IssueRef(repo: nil, number: 12))])

      #expect(refs(result).isEmpty)
    }

    @Test func aBranchInTheRepositoryWrittenInAnotherCaseCoversTheIssue() {
      let result = build(
        issues: [issue(12)],
        sessions: [sessionRow(repository: "Haacked/Switchboard", branch: "haacked/12-fix-the-thing")])

      #expect(refs(result).isEmpty)
    }

    @Test func aBranchWithAnotherNumberDoesNotCoverTheIssue() {
      #expect(refs(build(issues: [issue(12)], sessions: [sessionRow(branch: "haacked/120-other")])) == ["#12"])
    }

    @Test func anIssueCoveredByASessionsIssueLinkIsLeftOut() {
      let result = build(issues: [issue(12)], sessions: [sessionRow(issue: IssueRef(repo: repo, number: 12))])

      #expect(refs(result).isEmpty)
    }

    /// An issue link without a repository names an issue in the session's repository.
    @Test func anIssueLinkWithoutARepositoryCoversTheIssueOfASessionInTheRepository() {
      let result = build(issues: [issue(12)], sessions: [sessionRow(issue: IssueRef(number: 12))])

      #expect(refs(result).isEmpty)
    }

    /// The link names its own repository, so the session's checkout repository doesn't matter.
    @Test func anIssueLinkFromASessionInAnotherRepositoryCoversTheIssue() {
      let result = build(
        issues: [issue(12)],
        sessions: [sessionRow(repository: "haacked/dotfiles", issue: IssueRef(repo: repo, number: 12))])

      #expect(refs(result).isEmpty)
    }

    @Test func anIssueLinkToTheSameNumberInAnotherRepositoryDoesNotCoverTheIssue() {
      let result = build(
        issues: [issue(12)], sessions: [sessionRow(issue: IssueRef(repo: "haacked/dotfiles", number: 12))])

      #expect(refs(result) == ["#12"])
    }

    @Test func anIssueLinkInTheRepositoryWrittenInAnotherCaseCoversTheIssue() {
      let result = build(
        issues: [issue(12)], sessions: [sessionRow(issue: IssueRef(repo: "Haacked/Switchboard", number: 12))])

      #expect(refs(result).isEmpty)
    }

    @Test func anIssueClosedByASessionsPRIsLeftOut() {
      let result = build(issues: [issue(12)], sessions: [sessionRow(closesIssues: [IssueRef(repo: repo, number: 12)])])

      #expect(refs(result).isEmpty)
    }

    @Test func anIssueClosedByOneOfSeveralClosingRefsIsLeftOut() {
      let closes = [IssueRef(repo: repo, number: 3), IssueRef(repo: repo, number: 12)]

      #expect(refs(build(issues: [issue(12)], sessions: [sessionRow(closesIssues: closes)])).isEmpty)
    }

    /// A closing ref without a repository names an issue in the PR's repository.
    @Test func aClosingRefWithoutARepositoryCoversTheIssueOfASessionInTheRepository() {
      let result = build(issues: [issue(12)], sessions: [sessionRow(closesIssues: [IssueRef(number: 12)])])

      #expect(refs(result).isEmpty)
    }

    @Test func aClosingRefToTheSameNumberInAnotherRepositoryDoesNotCoverTheIssue() {
      let result = build(
        issues: [issue(12)], sessions: [sessionRow(closesIssues: [IssueRef(repo: "haacked/dotfiles", number: 12)])])

      #expect(refs(result) == ["#12"])
    }

    @Test func anIssueCoveredByAnOpenPRsHeadBranchIsLeftOut() {
      let result = build(issues: [issue(12), issue(13)], openPRs: [openPR(40, head: "someone/12-fix-the-thing")])

      #expect(refs(result) == ["#13"])
    }

    @Test func anIssueCoveredByAnOpenPRsClosingReferenceIsLeftOut() {
      let result = build(issues: [issue(12)], openPRs: [openPR(40, closes: [IssueRef(repo: repo, number: 12)])])

      #expect(refs(result).isEmpty)
    }

    @Test func anOpenPRsClosingReferenceWithoutARepositoryCoversTheIssue() {
      let result = build(issues: [issue(12)], openPRs: [openPR(40, closes: [IssueRef(number: 12)])])

      #expect(refs(result).isEmpty)
    }

    @Test func anOpenPRsClosingReferenceToAnotherRepositoryDoesNotCoverTheIssue() {
      let result = build(
        issues: [issue(12)], openPRs: [openPR(40, closes: [IssueRef(repo: "haacked/dotfiles", number: 12)])])

      #expect(refs(result) == ["#12"])
    }

    @Test func anOpenPRWhoseHeadBranchNamesNoIssueCoversNothing() {
      #expect(refs(build(issues: [issue(12)], openPRs: [openPR(40, head: "haacked/fix-the-thing")])) == ["#12"])
    }

    /// The open PR's own number is not an issue it covers.
    @Test func anOpenPRWithTheIssuesNumberCoversNothingByItsNumber() {
      #expect(refs(build(issues: [issue(40)], openPRs: [openPR(40, head: "haacked/fix-the-thing")])) == ["#40"])
    }

    @Test func aCoveredIssueIsNotListedAsASkip() {
      let result = build(issues: [issue(12)], sessions: [sessionRow(branch: "haacked/12-fix-the-thing")])

      #expect(!result.skips.contains { $0.ref == "#12" })
    }
  }
}

// MARK: - Trust

extension TopupCandidatesTests {
  @Suite struct Trust {
    @Test func anIssueByAnOutsideAuthorIsNotACandidate() {
      #expect(refs(build(issues: [issue(12, author: "mallory")])).isEmpty)
    }

    @Test func anIssueByAnOutsideAuthorIsSkippedWithTheReason() {
      let result = build(issues: [issue(12, author: "mallory")])

      #expect(
        result.skips == [Schedule.Gate.Skip(ref: "#12", reason: "written by mallory, who isn't you or a teammate")])
    }

    @Test func anIssueByTheViewerIsACandidate() {
      #expect(refs(build(issues: [issue(12, author: viewer)])) == ["#12"])
    }

    @Test func anIssueByTheViewerInAnotherCaseIsACandidate() {
      #expect(refs(build(issues: [issue(12, author: "Haacked")])) == ["#12"])
    }

    @Test func anIssueByATeammateIsACandidate() {
      #expect(refs(build(issues: [issue(12, author: "alice")])) == ["#12"])
    }

    @Test func anIssueWithNoAuthorIsSkipped() {
      let result = build(issues: [issue(12, author: nil)])

      #expect(refs(result).isEmpty)
      #expect(result.skips.map(\.ref) == ["#12"])
    }

    @Test func anUnknownViewerTrustsNotEvenTheViewersLogin() {
      let result = build(issues: [issue(12, author: viewer)], viewer: nil)

      #expect(refs(result).isEmpty)
      #expect(result.skips.map(\.ref) == ["#12"])
    }

    /// `IssueInbox.trusts` trusts the team's people even without a viewer. Decision 39 says an unknown viewer trusts
    /// nothing, so the top-up skips a teammate's issue too.
    @Test func anUnknownViewerTrustsNotEvenATeammate() {
      let result = build(issues: [issue(12, author: "alice")], viewer: nil)

      #expect(refs(result).isEmpty)
      #expect(result.skips.map(\.ref) == ["#12"])
    }

    @Test func untrustedIssuesAreSkippedWhileTrustedOnesStayCandidates() {
      let result = build(issues: [issue(12, author: "mallory"), issue(13), issue(14, author: "eve")])

      #expect(refs(result) == ["#13"])
      #expect(Set(result.skips.map(\.ref)) == ["#12", "#14"])
    }
  }
}

// MARK: - Follow-ups

extension TopupCandidatesTests {
  @Suite struct FollowupCandidates {
    @Test func aFollowupOfTheRepositoryAndGroupIsACandidate() {
      #expect(refs(build(followups: [waitingFollowup("f1")])) == ["followup:f1"])
    }

    @Test func aFollowupInTheRepositoryWrittenInAnotherCaseIsACandidate() {
      #expect(refs(build(followups: [waitingFollowup("f1", repository: "Haacked/Switchboard")])) == ["followup:f1"])
    }

    @Test func aFollowupOfAnotherRepositoryIsLeftOut() {
      #expect(refs(build(followups: [waitingFollowup("f1", repository: "haacked/dotfiles")])).isEmpty)
    }

    @Test func aFollowupWithNoRepositoryIsLeftOut() {
      #expect(refs(build(followups: [waitingFollowup("f1", repository: nil)])).isEmpty)
    }

    @Test func aFollowupOfAnotherGroupIsLeftOut() {
      #expect(refs(build(followups: [waitingFollowup("f1", group: "zz11aa")])).isEmpty)
    }

    @Test func aFollowupInNoGroupIsLeftOut() {
      #expect(refs(build(followups: [waitingFollowup("f1", group: nil)])).isEmpty)
    }

    @Test func aFollowupThatHasStartedIsLeftOut() {
      #expect(refs(build(followups: [waitingFollowup("f1", started: 5)])).isEmpty)
    }

    @Test func aFollowupWhoseDateHasNotFiredIsLeftOut() {
      #expect(refs(build(followups: [waitingFollowup("f1", trigger: .date(5_000))])).isEmpty)
    }

    @Test func aFollowupWhoseMergeHasNotFiredIsLeftOut() {
      #expect(refs(build(followups: [waitingFollowup("f1", trigger: mergeTrigger)])).isEmpty)
    }

    @Test func aFollowupWhoseDateFiredIsACandidate() {
      #expect(refs(build(followups: [waitingFollowup("f1", trigger: .date(5_000), ready: 6_000)])) == ["followup:f1"])
    }

    @Test func aFollowupWhoseMergeFiredIsACandidate() {
      #expect(refs(build(followups: [waitingFollowup("f1", trigger: mergeTrigger, ready: 6_000)])) == ["followup:f1"])
    }

    @Test func aManualFollowupMarkedDoneIsLeftOut() {
      #expect(refs(build(followups: [waitingFollowup("f1", done: true)])).isEmpty)
    }

    @Test func aFiredFollowupMarkedDoneIsLeftOut() {
      #expect(refs(build(followups: [waitingFollowup("f1", trigger: .date(5_000), ready: 6_000, done: true)])).isEmpty)
    }

    @Test func issuesAndFollowupsAreCandidatesTogether() {
      let result = build(
        issues: [issue(12)], followups: [waitingFollowup("f1"), waitingFollowup("f2", group: "zz11aa")])

      #expect(Set(refs(result)) == ["#12", "followup:f1"])
    }
  }
}
