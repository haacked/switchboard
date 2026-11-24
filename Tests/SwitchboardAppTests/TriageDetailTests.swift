import Foundation
import Testing

@testable import SwitchboardApp
@testable import SwitchboardCore

@Suite struct TriageDetailPane {
  func session(waitsToStart: Bool) -> SessionSummary {
    var s = needsItem("a")
    if waitsToStart { s.followup = Followup(prompt: "p") }
    return s
  }

  @Test func showsTheSummaryOfAnUnstartedFollowUpWhileTerminalIsOn() {
    let s = session(waitsToStart: true)
    #expect(s.waitsToStart)
    #expect(TriageDetail.pane(for: s, showingTerminal: true) == .summary)
  }

  @Test func showsTheTerminalOfAStartedFollowUpWhileTerminalIsOn() {
    var s = session(waitsToStart: true)
    s.followup?.started = 1
    #expect(!s.waitsToStart)
    #expect(TriageDetail.pane(for: s, showingTerminal: true) == .terminal)
  }

  @Test func showsTheSummaryOfADocketRowWhileTerminalIsOn() {
    #expect(TriageDetail.pane(for: docketRow(url: "https://github.com/o/r/pull/1"), showingTerminal: true) == .summary)
  }

  @Test func showsTheTerminalOfAStartedSessionWhileTerminalIsOn() {
    #expect(TriageDetail.pane(for: session(waitsToStart: false), showingTerminal: true) == .terminal)
  }

  /// The summary holds Retry and Keep.
  @Test func showsTheSummaryOfAFailedRemovalWhileTerminalIsOn() {
    #expect(TriageDetail.pane(for: removalSession("f", .failed), showingTerminal: true) == .summary)
  }

  @Test func showsTheSummaryWhileTerminalIsOff() {
    #expect(TriageDetail.pane(for: session(waitsToStart: false), showingTerminal: false) == .summary)
  }

  func docketRow(url: String) -> SessionSummary {
    var s = session(waitsToStart: false)
    s.cwd = ""
    s.docket = DocketSummary(DocketSession(pullRequest: "o/r#1", url: url), DocketStatus())
    // The bar must link a docket row to docket's URL and never show this `pr` or its code owners.
    s.pr = prWithOwners()
    return s
  }

  func prWithOwners() -> PRSummary {
    var pr = PRSummary(PullRequest(id: "PR_5", number: 5, url: "https://github.com/o/r/pull/5", repo: "o/r"))
    pr.codeOwners = CodeOwnerStatus(satisfied: false, groups: [])
    return pr
  }

  @Test func linksADocketRowToItsPullRequest() throws {
    let link = try #require(TriageDetail.prLink(for: docketRow(url: "https://github.com/o/r/pull/1")))
    #expect(link.label == "#1")
    #expect(link.help == "o/r#1")
    #expect(link.url == URL(string: "https://github.com/o/r/pull/1"))
    #expect(link.owners == nil)
  }

  @Test func helpsADocketRowWithItsReviewTitle() throws {
    var s = docketRow(url: "https://github.com/o/r/pull/1")
    var review = DocketReview(pullRequest: "o/r#1", url: "https://github.com/o/r/pull/1", state: "reviewing")
    review.title = "Fix it"
    s.docket?.review = review
    let link = try #require(TriageDetail.prLink(for: s))
    #expect(link.help == "o/r#1: Fix it")
  }

  @Test func keepsTheWholeDocketRefWhenItHasNoNumber() throws {
    var s = docketRow(url: "https://github.com/o/r/pull/1")
    s.docket?.pullRequest = "not a ref"
    let link = try #require(TriageDetail.prLink(for: s))
    #expect(link.label == "not a ref")
  }

  @Test func refusesADocketUrlThatIsNotHttps() {
    #expect(TriageDetail.prLink(for: docketRow(url: "http://github.com/o/r/pull/1")) == nil)
  }

  @Test func linksASessionToItsPullRequest() throws {
    var s = session(waitsToStart: false)
    s.pr = prWithOwners()
    let link = try #require(TriageDetail.prLink(for: s))
    #expect(link.label == "#5")
    #expect(link.help == s.pr?.line)
    #expect(link.url == URL(string: "https://github.com/o/r/pull/5"))
    #expect(link.owners == s.pr?.codeOwners)
  }

  @Test func hasNoPullRequestLinkForASessionWithoutOne() {
    #expect(TriageDetail.prLink(for: session(waitsToStart: false)) == nil)
  }
}

/// The header names the PR's branch when the folder is on another one.
@Suite struct TriageDetailPRHead {
  func session(branch: String?, head: String) -> SessionSummary {
    var s = needsItem("a")
    s.branch = branch
    s.pr = PRSummary(PullRequest(id: "PR_5", number: 5, url: "https://github.com/o/r/pull/5", repo: "o/r", head: head))
    return s
  }

  @Test func linkNamesTheHeadWhenItDiffersFromTheFoldersBranch() throws {
    let link = try #require(TriageDetail.prLink(for: session(branch: "haacked/x-v2", head: "haacked/x")))

    #expect(link.head == "haacked/x")
  }

  @Test func linkHasNoHeadWhenItIsTheFoldersBranch() throws {
    let link = try #require(TriageDetail.prLink(for: session(branch: "haacked/x", head: "haacked/x")))

    #expect(link.head == nil)
  }

  /// A narrow header drops the branch, so the link's help names it.
  @Test func helpNamesTheBranchWhenItIsTheFoldersBranch() throws {
    let link = try #require(TriageDetail.prLink(for: session(branch: "haacked/x", head: "haacked/x")))

    #expect(link.help.hasSuffix(". The PR's branch is haacked/x."))
  }

  @Test func helpNamesBothBranchesWhenTheyDiffer() throws {
    let link = try #require(TriageDetail.prLink(for: session(branch: "haacked/x-v2", head: "haacked/x")))

    #expect(link.help.hasSuffix(". The PR's branch is haacked/x. This folder is on haacked/x-v2."))
  }

  @Test func linkHasNoHeadWhenThePRDoesNotNameOne() throws {
    let link = try #require(TriageDetail.prLink(for: session(branch: "haacked/x-v2", head: "")))

    #expect(link.head == nil)
  }

  @Test func aDocketRowLinksWithoutAHead() throws {
    var s = session(branch: "haacked/x-v2", head: "haacked/x")
    s.cwd = ""
    s.docket = DocketSummary(DocketSession(pullRequest: "o/r#1", url: "https://github.com/o/r/pull/1"), DocketStatus())

    let link = try #require(TriageDetail.prLink(for: s))

    #expect(link.head == nil)
  }
}
