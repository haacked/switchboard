import Foundation
import Testing

@testable import SwitchboardApp
@testable import SwitchboardCore

private let hour: Int64 = 3_600_000
private let now: Int64 = 100 * hour

private func gitHubRef(_ repo: String, _ number: Int) -> GitHubRef { GitHubRef(repo: repo, number: number)! }

/// The session that holds `waits`, with an open PR on `pr` and a GitHub `repository` when they are given.
private func holder(pr: (repo: String, number: Int)? = nil, repository: String? = nil, waits: [Wait]) -> SessionSummary
{
  var s = needsItem("s1")
  if let pr {
    s.pr = PRSummary(
      PullRequest(
        id: "PR_\(pr.number)", number: pr.number, url: "https://github.com/\(pr.repo)/pull/\(pr.number)",
        repo: pr.repo))
  }
  s.repository = repository
  s.waits = waits
  return s
}

private func wait(
  _ kind: Wait.Kind = .ci, id: String = "w1", pr: Wait.PullRequest? = nil, who: String? = nil,
  note: String? = nil, by: Author = .you, created: Int64 = now - 3 * hour, then: Wait.Then = .resume,
  recheck: Int64? = now - hour, until: Int64? = nil, target: Wait.SessionTarget? = nil
) -> Wait {
  Wait(
    id: id, kind: kind, pr: pr, session: target, who: who, until: until, note: note, by: by, created: created,
    then: then, recheck: recheck)
}

private func prDetails(
  _ repo: String = "acme/widgets", _ number: Int = 7, state: ReferenceDetails.State = .open,
  requests: [String]? = nil
) -> ReferenceDetails {
  ReferenceDetails(
    repo: repo, number: number, kind: .pr, title: "Add the widget", url: "https://github.com/\(repo)/pull/\(number)",
    state: state, draft: false, author: "ann", labels: [], createdAt: nil, updatedAt: nil, checks: "SUCCESS",
    reviewDecision: .reviewRequired, mergeable: nil, reviewRequests: requests)
}

/// The panel's rows for every wait of `session`, or for `ids`, with the loaded references in `loads` by key.
private func rows(
  _ session: SessionSummary, ids: [String]? = nil, sessions: [SessionSummary] = [],
  loads: [String: ReferenceLoad] = [:]
) -> [WaitPanel.Row] {
  WaitPanel.rows(
    session: session, ids: ids ?? session.waits.map(\.id), sessions: sessions, reference: { loads[$0.key] },
    now: now)
}

private func onlyRow(
  _ session: SessionSummary, sessions: [SessionSummary] = [], loads: [String: ReferenceLoad] = [:]
) throws -> WaitPanel.Row {
  let all = rows(session, sessions: sessions, loads: loads)
  try #require(all.count == 1)
  return all[0]
}

private let prKinds: [Wait.Kind] = [.ci, .review, .botReview, .approval, .queue, .merge, .deploy]

private let slackChannel = "C0EXAMPLE01"
private let slackRootTs = "1794965000.000100"
private let slackRoot = "https://example.slack.com/archives/\(slackChannel)/p1794965000000100"
private let slackReply =
  "https://example.slack.com/archives/\(slackChannel)/p1794965246462679?thread_ts=\(slackRootTs)&cid=\(slackChannel)"

/// A reply wait on `url` with the thread status that a session summary gives it.
private func replyWait(url: String = slackRoot, status: SlackThreadStatus? = nil) -> Wait {
  var w = wait(.reply, recheck: now - hour)
  w.url = url
  w.threadStatus = status
  return w
}

/// The time of the reply tests' thread reads. `SlackPoll.tsValue` reads only a ts with 10 digits of seconds, so the
/// tests' `now` is too early for a reply's ts.
private let slackNow: Int64 = 1_794_968_600_000

/// A Slack ts for a time in ms.
private func slackTs(_ ms: Int64) -> String { String(format: "%lld.%06lld", ms / 1000, (ms % 1000) * 1000) }

/// The status of the `slackRoot` thread as a session summary gives it at `slackNow`. A read thread has `replies`
/// replies, the last from Alice 2h ago, and was read 1h ago. The user last looked 3h ago, so Alice's reply is new.
private func threadStatus(replies: Int? = 2, error: String? = nil) throws -> SlackThreadStatus {
  let target = try #require(LinkTarget.parse(slackRoot))
  var row = SlackThread(channel: slackChannel, thread: slackRootTs)
  row.replies = replies
  if replies != nil { row.read = slackNow - hour }
  if let replies, replies > 0 {
    row.lastReplyTs = slackTs(slackNow - 2 * hour)
    row.lastReplyUser = "U0OTHER"
    row.lastReplyName = "Alice"
  }
  row.error = error
  return try #require(SlackThreadStatus(target: target, row: row, watched: true, lookedAt: slackNow - 3 * hour))
}

// MARK: The rows and their facts

@Suite struct WaitPanelRows {
  @Test func eachOverdueIdGivesOneRowInTheOrderOfTheIds() {
    let session = holder(waits: [wait(.date, id: "w1"), wait(.date, id: "w2"), wait(.date, id: "w3")])

    #expect(rows(session, ids: ["w3", "w1"]).map(\.id) == ["w3", "w1"])
  }

  /// A wait that sbd cleared or resolved since the item was built has nothing left to show.
  @Test func anIdThatNamesNoWaitOfTheSessionGivesNoRow() {
    let session = holder(waits: [wait(.date, id: "w1")])

    #expect(rows(session, ids: ["gone"]).isEmpty)
  }

  @Test func aRowShowsTheWaitsSummary() throws {
    let w = wait(.review, pr: Wait.PullRequest(repository: "acme/widgets", number: 7), who: "alice")

    #expect(try onlyRow(holder(waits: [w])).summary == w.summary)
  }

  @Test(arguments: [(Author.you, "Set 3h ago by you"), (.claude, "Set 3h ago by claude")])
  func aRowSaysWhenAndByWhomTheWaitWasSet(_ by: Author, _ line: String) throws {
    let w = wait(.date, by: by, created: now - 3 * hour, until: now)

    #expect(try onlyRow(holder(waits: [w])).set == line)
  }

  @Test func aRowCarriesTheNote() throws {
    #expect(try onlyRow(holder(waits: [wait(.date, note: "Asked in Slack", until: now)])).note == "Asked in Slack")
  }

  @Test func aRowWithoutANoteHasNone() throws {
    #expect(try onlyRow(holder(waits: [wait(.date, until: now)])).note == nil)
  }

  @Test(arguments: [Wait.Then.resume, .notify, .caller])
  func aRowSaysWhatHappensWhenTheWaitResolves(_ then: Wait.Then) throws {
    #expect(try onlyRow(holder(waits: [wait(.date, then: then, until: now)])).then == then)
  }

  @Test(arguments: prKinds + [.session])
  func aRowCarriesTheWaitsRecheckTime(_ kind: Wait.Kind) throws {
    let w = wait(kind, recheck: now - hour, until: now - 2 * hour)

    #expect(try onlyRow(holder(waits: [w])).recheck == now - hour)
  }

  /// A manual wait has no `recheck`: its `until` is when it returns to Needs you.
  @Test func aManualWaitsRowCarriesItsUntil() throws {
    let w = wait(.manual, note: "Ask Ann", recheck: nil, until: now - 2 * hour)

    #expect(try onlyRow(holder(waits: [w])).recheck == now - 2 * hour)
  }

  /// A manual wait's summary is its note, so the row doesn't repeat it.
  @Test func aManualWaitsRowHasNoNote() throws {
    let w = wait(.manual, note: "Ask Ann", recheck: nil, until: now - 2 * hour)

    #expect(try onlyRow(holder(waits: [w])).note == nil)
  }

  @Test func theFactsLineSaysWhoSetTheWaitWhenItsRecheckWasDueAndWhatHappensNext() throws {
    let row = try onlyRow(holder(waits: [wait(.ci, created: now - 3 * hour, then: .notify, recheck: now - hour)]))

    #expect(
      WaitPanel.facts(row, now: now)
        == "Set 3h ago by you · recheck was due 1h ago · moves to Needs you when it resolves")
  }

  @Test func theFactsLineOfAFutureRecheckSaysWhenItComes() throws {
    let row = try onlyRow(holder(waits: [wait(.ci, created: now - 3 * hour, then: .notify, recheck: now + 3 * hour)]))

    #expect(
      WaitPanel.facts(row, now: now) == "Set 3h ago by you · rechecks in 3h · moves to Needs you when it resolves")
  }

  @Test(arguments: [(-2, "due 2h ago"), (3, "due in 3h")])
  func theFactsLineOfAManualWaitSaysWhenItIsDue(_ hours: Int64, _ phrase: String) throws {
    let w = wait(
      .manual, note: "Ask Ann", created: now - 3 * hour, then: .notify, recheck: nil, until: now + hours * hour)

    #expect(
      WaitPanel.facts(try onlyRow(holder(waits: [w])), now: now)
        == "Set 3h ago by you · \(phrase) · moves to Needs you when it resolves")
  }

  @Test func theFactsLineOfAWaitThatSbdNeverRecheckedLeavesTheRecheckOut() throws {
    let row = try onlyRow(holder(waits: [wait(.date, created: now - 3 * hour, recheck: nil, until: now)]))

    #expect(WaitPanel.facts(row, now: now) == "Set 3h ago by you · resumes claude when it resolves")
  }
}

// MARK: The target and its state

@Suite struct WaitPanelTargets {
  @Test(arguments: prKinds)
  func everyPRKindReadsThePRThatTheWaitNames(_ kind: Wait.Kind) throws {
    let w = wait(kind, pr: Wait.PullRequest(repository: "acme/other", number: 9))
    let session = holder(pr: ("acme/widgets", 1), repository: "acme/widgets", waits: [w])

    #expect(try onlyRow(session).pr == gitHubRef("acme/other", 9))
  }

  @Test func aPRWithoutARepositoryReadsTheRepositoryOfTheSessionsPR() throws {
    let w = wait(.ci, pr: Wait.PullRequest(number: 7))
    let session = holder(pr: ("acme/widgets", 1), repository: "acme/fork", waits: [w])

    #expect(try onlyRow(session).pr == gitHubRef("acme/widgets", 7))
  }

  @Test func aPRWithoutARepositoryOnASessionWithoutAPRReadsTheSessionsRepository() throws {
    let w = wait(.ci, pr: Wait.PullRequest(number: 7))
    let session = holder(repository: "acme/fork", waits: [w])

    #expect(try onlyRow(session).pr == gitHubRef("acme/fork", 7))
  }

  @Test(arguments: prKinds)
  func aWaitWithoutAPRReadsTheSessionsOwnPR(_ kind: Wait.Kind) throws {
    let session = holder(pr: ("acme/widgets", 1), repository: "acme/fork", waits: [wait(kind)])

    #expect(try onlyRow(session).pr == gitHubRef("acme/widgets", 1))
  }

  /// A guess at the repository would show another PR's state.
  @Test func aPRWithoutARepositoryOnASessionWithNeitherAPRNorARepositoryIsUnresolved() throws {
    let row = try onlyRow(holder(waits: [wait(.ci, pr: Wait.PullRequest(number: 7))]))

    #expect(row.target == .unresolved)
    #expect(row.pr == nil)
  }

  @Test func aWaitWithoutAPROnASessionWithoutAPRIsUnresolved() throws {
    let row = try onlyRow(holder(repository: "acme/widgets", waits: [wait(.ci)]))

    #expect(row.target == .unresolved)
    #expect(row.pr == nil)
  }

  @Test(arguments: ["not a repo", "acme", ""])
  func aRepositoryThatGitHubCannotNameIsUnresolved(_ repository: String) throws {
    let row = try onlyRow(holder(waits: [wait(.ci, pr: Wait.PullRequest(repository: repository, number: 7))]))

    #expect(row.target == .unresolved)
    #expect(row.pr == nil)
  }

  @Test(arguments: [nil, ReferenceLoad.loading])
  func aPRThatHasNotLoadedShowsLoading(_ load: ReferenceLoad?) throws {
    let ref = gitHubRef("acme/widgets", 7)
    let session = holder(waits: [wait(.ci, pr: Wait.PullRequest(repository: "acme/widgets", number: 7))])

    let row = try onlyRow(session, loads: load.map { [ref.key: $0] } ?? [:])

    #expect(row.target == .pullRequest(ref, .loading))
  }

  @Test(arguments: [
    ReferenceLoad.loaded(prDetails()), .loaded(prDetails(state: .merged)), .notFound, .failed("rate limited"),
  ])
  func aPRShowsWhatItsReadGave(_ load: ReferenceLoad) throws {
    let ref = gitHubRef("acme/widgets", 7)
    let session = holder(waits: [wait(.ci, pr: Wait.PullRequest(repository: "acme/widgets", number: 7))])

    #expect(try onlyRow(session, loads: [ref.key: load]).target == .pullRequest(ref, load))
  }

  /// The read of the session's own PR is the one that the lookup gets, not one keyed by the wait alone.
  @Test func aWaitWithoutAPRShowsTheReadOfTheSessionsPR() throws {
    let details = prDetails("acme/widgets", 1)
    let session = holder(pr: ("acme/widgets", 1), waits: [wait(.merge)])

    let ref = gitHubRef("acme/widgets", 1)

    let row = try onlyRow(session, loads: [ref.key: .loaded(details)])

    #expect(row.target == .pullRequest(ref, .loaded(details)))
  }

  @Test func aSessionWaitShowsItsTargetsCurrentState() throws {
    let w = wait(.session, target: Wait.SessionTarget(id: "s2", name: "flag-cache"))
    let other = needsItem("s2", state: .working)

    let row = try onlyRow(holder(waits: [w]), sessions: [other])

    #expect(row.target == .session(.working))
  }

  @Test func aSessionWaitWhoseTargetIsGoneSaysItWasRemoved() throws {
    let w = wait(.session, target: Wait.SessionTarget(id: "s2", name: "flag-cache"))

    #expect(try onlyRow(holder(waits: [w]), sessions: [needsItem("s3")]).target == .removed)
  }

  @Test(arguments: [Wait.Kind.session, .date, .manual, .reply])
  func aWaitThatIsNotOnAPRHasNoPR(_ kind: Wait.Kind) throws {
    let w = wait(kind, until: now - hour, target: Wait.SessionTarget(id: "s2", name: "flag-cache"))
    let session = holder(pr: ("acme/widgets", 1), waits: [w])

    #expect(try onlyRow(session, sessions: [needsItem("s2")]).pr == nil)
  }

  @Test(arguments: [Wait.Kind.date, .manual])
  func aTimedWaitShowsItsTime(_ kind: Wait.Kind) throws {
    let w = wait(kind, note: "Ask Ann", until: now - 2 * hour)

    #expect(try onlyRow(holder(waits: [w])).target == .time(now - 2 * hour))
  }

  @Test func aReplyWaitReadsItsThreadAndItsStatus() throws {
    let status = try threadStatus()

    #expect(try onlyRow(holder(waits: [replyWait(status: status)])).target == .thread(url: slackRoot, status: status))
  }

  /// D3: the wait keeps the link the user gave, so Open thread opens the reply that the user linked.
  @Test func aReplyLinkIsTheThreadsURL() throws {
    let status = try threadStatus()

    let row = try onlyRow(holder(waits: [replyWait(url: slackReply, status: status)]))

    #expect(row.target == .thread(url: slackReply, status: status))
  }

  /// A summary gives no status before sbd's poll reads the thread or watches it.
  @Test func aReplyWaitWithoutAThreadStatusHasNoStatus() throws {
    #expect(try onlyRow(holder(waits: [replyWait(status: nil)])).target == .thread(url: slackRoot, status: nil))
  }

  @Test func aReplyWaitHasNoPREvenOnASessionWithAPR() throws {
    let session = holder(pr: ("acme/widgets", 1), repository: "acme/widgets", waits: [replyWait()])

    #expect(try onlyRow(session).pr == nil)
  }

  @Test func aReadThreadShowsItsStatusLine() throws {
    let status = try threadStatus()
    let row = try onlyRow(holder(waits: [replyWait(status: status)]))

    #expect(WaitPanel.targetLines(row, now: slackNow) == [status.line(now: slackNow)])
  }

  @Test func theStatusLineSaysHowManyRepliesWhoSentTheLastAndWhenSbdReadTheThread() throws {
    let row = try onlyRow(holder(waits: [replyWait(status: try threadStatus())]))

    #expect(WaitPanel.targetLines(row, now: slackNow) == ["2 replies, last from Alice 2h ago, read 1h ago, new reply"])
  }

  @Test func aThreadWithoutRepliesSaysSo() throws {
    let row = try onlyRow(holder(waits: [replyWait(status: try threadStatus(replies: 0))]))

    #expect(WaitPanel.targetLines(row, now: slackNow) == ["no replies, read 1h ago"])
  }

  @Test func aThreadThatSbdHasNotReadYetSaysSo() throws {
    let row = try onlyRow(holder(waits: [replyWait(status: nil)]))

    #expect(WaitPanel.targetLines(row, now: slackNow) == ["sbd hasn't read the thread yet"])
  }

  @Test(arguments: [nil, 2])
  func aThreadWhoseReadFailedShowsTheError(_ replies: Int?) throws {
    let status = try threadStatus(replies: replies, error: "the Slack connector timed out")
    let row = try onlyRow(holder(waits: [replyWait(status: status)]))

    let lines = WaitPanel.targetLines(row, now: slackNow)

    #expect(lines == [status.line(now: slackNow)])
    #expect(lines.first?.contains("the Slack connector timed out") == true)
  }

  @Test func checkNowOnAThreadSaysWhenSbdReadsIt() {
    #expect(
      WaitPanel.threadCheckHelp
        == "Read this thread first at sbd's next Slack poll. The wait resolves when the poll finds a reply from someone else."
    )
  }

  /// sbd exposes no deploy state, so the panel says who checks it.
  @Test func aDeployWaitSaysThatSbdChecksTheDeploy() throws {
    let session = holder(pr: ("acme/widgets", 1), waits: [wait(.deploy)])

    #expect(try onlyRow(session).footnote == "sbd checks the deploy on its own")
  }

  @Test(arguments: [Wait.Kind.ci, .review, .botReview, .approval, .queue, .merge, .session, .date, .manual, .reply])
  func onlyADeployWaitHasTheDeployLine(_ kind: Wait.Kind) throws {
    let w = wait(kind, until: now - hour, target: Wait.SessionTarget(id: "s2", name: "flag-cache"))
    let session = holder(pr: ("acme/widgets", 1), waits: [w])

    #expect(try onlyRow(session, sessions: [needsItem("s2")]).footnote == nil)
  }
}

// MARK: Whether the reviewer is still requested

@Suite struct WaitPanelReviewer {
  private func requested(
    _ kind: Wait.Kind = .review, who: String? = "alice", load: ReferenceLoad?
  ) throws -> Bool? {
    let ref = gitHubRef("acme/widgets", 7)
    let w = wait(kind, pr: Wait.PullRequest(repository: "acme/widgets", number: 7), who: who)
    return try onlyRow(holder(waits: [w]), loads: load.map { [ref.key: $0] } ?? [:]).requested
  }

  @Test(arguments: [Wait.Kind.review, .approval])
  func aReviewerThatGitHubStillRequestsSaysSo(_ kind: Wait.Kind) throws {
    #expect(try requested(kind, load: .loaded(prDetails(requests: ["bob", "alice"]))) == true)
  }

  @Test(arguments: [Wait.Kind.review, .approval])
  func aReviewerThatGitHubNoLongerRequestsSaysSo(_ kind: Wait.Kind) throws {
    #expect(try requested(kind, load: .loaded(prDetails(requests: ["bob"]))) == false)
  }

  /// GitHub names a team by its slug alone.
  @Test func aTeamReviewerMatchesItsSlug() throws {
    let load = ReferenceLoad.loaded(prDetails(requests: ["clickhouse"]))

    #expect(try requested(who: "PostHog/clickhouse", load: load) == true)
  }

  @Test func anUnreadRequestListSaysNothing() throws {
    #expect(try requested(load: .loaded(prDetails(requests: nil))) == nil)
  }

  @Test(arguments: [nil, ReferenceLoad.loading, .notFound, .failed("rate limited")])
  func aPRWithoutLoadedDetailsSaysNothingAboutTheReviewer(_ load: ReferenceLoad?) throws {
    #expect(try requested(load: load) == nil)
  }

  @Test func aWaitWithoutAReviewerSaysNothing() throws {
    #expect(try requested(who: nil, load: .loaded(prDetails(requests: ["alice"]))) == nil)
  }

  /// The panel shows who GitHub still waits on for every PR kind, not only for a named reviewer.
  @Test(arguments: [Wait.Kind.ci, .botReview, .queue, .merge, .deploy])
  func aPRTargetShowsItsPendingReviewRequests(_ kind: Wait.Kind) throws {
    let ref = gitHubRef("acme/widgets", 7)
    let w = wait(kind, pr: Wait.PullRequest(repository: "acme/widgets", number: 7))
    let load = ReferenceLoad.loaded(prDetails(requests: ["bob", "clickhouse"]))

    #expect(try onlyRow(holder(waits: [w]), loads: [ref.key: load]).reviewRequests == ["bob", "clickhouse"])
  }

  @Test func aReviewWaitWithoutAReviewerShowsThePendingRequests() throws {
    let ref = gitHubRef("acme/widgets", 7)
    let w = wait(.review, pr: Wait.PullRequest(repository: "acme/widgets", number: 7))

    let row = try onlyRow(holder(waits: [w]), loads: [ref.key: .loaded(prDetails(requests: ["bob", "clickhouse"]))])

    #expect(row.reviewRequests == ["bob", "clickhouse"])
    #expect(row.requested == nil)
  }

  @Test(arguments: [nil, ReferenceLoad.loading, .notFound, .failed("rate limited")])
  func aPRThatHasNotLoadedShowsNoPendingRequests(_ load: ReferenceLoad?) throws {
    let ref = gitHubRef("acme/widgets", 7)
    let w = wait(.ci, pr: Wait.PullRequest(repository: "acme/widgets", number: 7))

    #expect(try onlyRow(holder(waits: [w]), loads: load.map { [ref.key: $0] } ?? [:]).reviewRequests == nil)
  }

  /// Decision 3 names only `review` and `approval`.
  @Test(arguments: [Wait.Kind.ci, .botReview, .queue, .merge, .deploy])
  func otherKindsSayNothingAboutTheReviewer(_ kind: Wait.Kind) throws {
    #expect(try requested(kind, load: .loaded(prDetails(requests: ["alice"]))) == nil)
  }

  private func targetLines(who: String? = "alice", requests: [String]?) throws -> [String] {
    let ref = gitHubRef("acme/widgets", 7)
    let w = wait(.review, pr: Wait.PullRequest(repository: "acme/widgets", number: 7), who: who)
    let row = try onlyRow(holder(waits: [w]), loads: [ref.key: .loaded(prDetails(requests: requests))])
    return WaitPanel.targetLines(row, now: now)
  }

  @Test func aStillRequestedReviewerReadsStillRequested() throws {
    let lines = try targetLines(requests: ["bob", "alice"])

    #expect(lines.contains("Review still requested: alice"))
    #expect(!lines.contains("Review no longer requested: alice"))
  }

  @Test func aReviewerNoLongerRequestedReadsNoLongerRequested() throws {
    let lines = try targetLines(requests: ["bob"])

    #expect(lines.contains("Review no longer requested: alice"))
    #expect(!lines.contains("Review still requested: alice"))
  }

  @Test func aTeamReviewerReadsAsItsSlug() throws {
    #expect(
      try targetLines(who: "PostHog/clickhouse", requests: ["clickhouse"]).contains(
        "Review still requested: clickhouse"))
  }

  @Test func thePendingRequestsShowAsOneLine() throws {
    #expect(try targetLines(requests: ["bob", "clickhouse"]).contains("Pending review requests: bob, clickhouse"))
  }

  @Test func anUnreadRequestListShowsNoReviewerLine() throws {
    let lines = try targetLines(requests: nil)

    #expect(!lines.contains { $0.hasPrefix("Review ") || $0.hasPrefix("Pending review requests") })
  }
}

// MARK: When the panel shows nothing

/// The panel shows nothing, its header included, when no id of the item names a wait that the session still has.
@Suite struct WaitPanelEmpty {
  @Test func anItemWithoutOverdueWaitsHasNoRows() {
    #expect(rows(holder(waits: [wait(id: "w1")]), ids: []).isEmpty)
  }

  /// The user or sbd cleared the wait since the item was built.
  @Test func anItemWhoseOverdueWaitsAreGoneHasNoRows() {
    #expect(rows(holder(waits: [wait(id: "w2")]), ids: ["w1"]).isEmpty)
  }

  @Test func anItemThatNamesAWaitOfTheSessionHasItsRow() {
    let session = holder(waits: [wait(id: "w1"), wait(id: "w2")])

    #expect(rows(session, ids: ["gone", "w2"]).map(\.id) == ["w2"])
  }
}

// MARK: Clear wait, Check now

/// `firstRequest` waits for ever when nothing is sent, so these tests wait at most 3 seconds for the request.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct WaitPanelActions {
  @Test func clearWaitSendsClearWaitWithTheSessionAndTheWait() async throws {
    let (model, sent) = recordingModel()

    model.clearWait("s1", wait: "w1")
    await sent.wait(for: "clear-wait")

    let request = try #require(sent.value.first { $0.op == "clear-wait" })
    #expect(request.args == ["session": "s1", "wait": "w1"])
  }

  @Test func checkNowSendsARefDetailsThatAsksForAFreshRead() async throws {
    let (model, sent) = recordingModel()

    model.checkReference(gitHubRef("acme/widgets", 7))
    await sent.wait(for: "ref-details")

    let request = try #require(sent.value.first { $0.op == "ref-details" })
    #expect(request.args == ["repo": "acme/widgets", "number": 7, "fresh": true])
  }

  @Test func checkNowStoresTheAnswerForTheReference() async throws {
    let model = offlineModel()
    let ref = gitHubRef("acme/widgets", 7)
    let answer = try JSON(encoding: ReferenceReply.found(prDetails(requests: ["alice"])))
    model.send = { _, _ in answer }

    model.checkReference(ref)
    await settle { model.references.details[ref.key] == .loaded(prDetails(requests: ["alice"])) }

    #expect(model.references.details[ref.key] == .loaded(prDetails(requests: ["alice"])))
  }

  /// A Check now click while an ordinary read is in flight still asks sbd to read GitHub again.
  @Test func checkNowSendsEvenWhileALoadIsInFlight() async {
    let (model, sent) = recordingModel()
    let ref = gitHubRef("acme/widgets", 7)
    model.references.inFlight.insert(ref.key)

    model.checkReference(ref)
    await sent.wait(for: "ref-details")

    #expect(sent.ops.contains("ref-details"))
  }

  /// An ordinary read that started before Check now can answer after it with sbd's cached details.
  @Test func aFreshAnswerWinsOverAnOrdinaryReadThatAnswersLater() async throws {
    let model = offlineModel()
    let ref = gitHubRef("acme/widgets", 7)
    let cached = try JSON(encoding: ReferenceReply.found(prDetails(requests: ["alice"])))
    let fresh = try JSON(encoding: ReferenceReply.found(prDetails(requests: ["bob"])))
    let release = DispatchSemaphore(value: 0)
    let ordinarySent = Counter()
    model.send = { _, args in
      if args["fresh"] == true { return fresh }
      ordinarySent.increment()
      release.wait()
      return cached
    }

    model.loadReference(ref)
    await settle { ordinarySent.value == 1 }
    model.checkReference(ref)
    await settle { model.references.details[ref.key] == .loaded(prDetails(requests: ["bob"])) }
    release.signal()
    try? await Task.sleep(nanoseconds: 200_000_000)

    #expect(model.references.details[ref.key] == .loaded(prDetails(requests: ["bob"])))
    #expect(!model.references.inFlight.contains(ref.key))
  }

  @Test func anOrdinaryReadAfterCheckNowStoresItsAnswer() async throws {
    let model = offlineModel()
    let ref = gitHubRef("acme/widgets", 7)
    let answers = [
      try JSON(encoding: ReferenceReply.found(prDetails(requests: ["bob"]))),
      try JSON(encoding: ReferenceReply.found(prDetails(requests: ["carol"]))),
    ]
    let sent = Counter()
    model.send = { _, _ in answers[min(sent.increment(), 2) - 1] }

    model.checkReference(ref)
    await settle { model.references.details[ref.key] == .loaded(prDetails(requests: ["bob"])) }
    model.loadReference(ref)
    await settle { model.references.details[ref.key] == .loaded(prDetails(requests: ["carol"])) }

    #expect(model.references.details[ref.key] == .loaded(prDetails(requests: ["carol"])))
  }

  /// A second click before sbd answers sends nothing, so it can't come back as a "no wait" refusal.
  @Test func aSecondClearWaitBeforeTheAnswerSendsNothing() async {
    let (model, release, requests) = heldModel()

    model.clearWait("s1", wait: "w1")
    await settle { requests.value == 1 }
    model.clearWait("s1", wait: "w1")
    try? await Task.sleep(nanoseconds: 100_000_000)
    let sentBeforeTheAnswer = requests.value
    release.signal()
    await settle { model.clearingWaits.isEmpty }

    #expect(sentBeforeTheAnswer == 1)
    #expect(model.waitErrors["s1"] == nil)
  }

  @Test func clearWaitCanBeClickedAgainAfterSbdAnswers() async {
    let (model, sent) = recordingModel()

    model.clearWait("s1", wait: "w1")
    await settle { model.clearingWaits.isEmpty && sent.ops.count == 1 }
    model.clearWait("s1", wait: "w1")
    await settle { sent.ops.count == 2 }

    #expect(sent.ops == ["clear-wait", "clear-wait"])
  }

  @Test func aRefusedClearWaitShowsInTheSessionsWaitRefusal() async {
    let (model, _) = recordingModel(refuse: { op, _ in op == "clear-wait" ? "s1 has no wait w1" : nil })

    model.clearWait("s1", wait: "w1")
    await settle { model.waitErrors["s1"] != nil }

    #expect(model.waitErrors["s1"]?.contains("s1 has no wait w1") == true)
  }

  /// The refusal shows beside the panel's buttons, not in the window's error banner.
  @Test func aRefusedClearWaitLeavesTheErrorBannerAlone() async {
    let (model, _) = recordingModel(refuse: { op, _ in op == "clear-wait" ? "s1 has no wait w1" : nil })

    model.clearWait("s1", wait: "w1")
    await settle { model.waitErrors["s1"] != nil }

    #expect(model.actionError == nil)
  }

  @Test func aClearWaitThatSucceedsRemovesTheEarlierRefusal() async {
    let (model, sent) = recordingModel()
    model.waitErrors["s1"] = "s1 has no wait w1"

    model.clearWait("s1", wait: "w1")
    await sent.wait(for: "clear-wait")
    await settle { model.waitErrors["s1"] == nil }

    #expect(model.waitErrors["s1"] == nil)
  }

  @Test func checkWaitSendsWaitCheckWithTheSessionTheWaitAndYou() async throws {
    let (model, sent) = recordingModel()

    model.checkWait(session: "s1", wait: "w1")
    await sent.wait(for: "wait-check")

    let request = try #require(sent.value.first { $0.op == "wait-check" })
    #expect(request.args == ["session": "s1", "wait": "w1", "by": "you"])
  }

  @Test func aRefusedCheckWaitShowsInTheSessionsWaitRefusal() async {
    let refusal = "sbd doesn't read Slack threads while slack.pollSeconds is 0"
    let (model, _) = recordingModel(refuse: { op, _ in op == "wait-check" ? refusal : nil })

    model.checkWait(session: "s1", wait: "w1")
    await settle { model.waitErrors["s1"] != nil }

    #expect(model.waitErrors["s1"]?.contains(refusal) == true)
  }

  /// The refusal shows beside the panel's buttons, not in the window's error banner.
  @Test func aRefusedCheckWaitLeavesTheErrorBannerAlone() async {
    let (model, _) = recordingModel(refuse: { op, _ in op == "wait-check" ? "s1 has no reply wait w1" : nil })

    model.checkWait(session: "s1", wait: "w1")
    await settle { model.waitErrors["s1"] != nil }

    #expect(model.actionError == nil)
  }

  @Test func aCheckWaitThatSucceedsRemovesTheEarlierRefusal() async {
    let (model, sent) = recordingModel()
    model.waitErrors["s1"] = "s1 has no reply wait w1"

    model.checkWait(session: "s1", wait: "w1")
    await sent.wait(for: "wait-check")
    await settle { model.waitErrors["s1"] == nil }

    #expect(model.waitErrors["s1"] == nil)
  }

  @Test func aRefusedCheckNowShowsAsAFailedRead() async {
    let (model, _) = recordingModel(refuse: { op, _ in op == "ref-details" ? "GitHub is rate limited" : nil })
    let ref = gitHubRef("acme/widgets", 7)

    model.checkReference(ref)
    await settle {
      if case .failed? = model.references.details[ref.key] { return true }
      return false
    }

    guard case .failed(let message)? = model.references.details[ref.key] else {
      Issue.record("no failed read for \(ref.key)")
      return
    }
    #expect(message.contains("GitHub is rate limited"))
    #expect(model.actionError == nil)
  }
}
