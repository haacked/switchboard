import Foundation
import Testing

@testable import SwitchboardCore

private let viewer = "robin-k"
private let team = IssueTeam(labels: ["team/billing"], people: ["ana-m", "dev-p", "kofi-a"])
private let inbox = IssueInbox(viewer: viewer, team: team)

private func issue(
  _ number: Int, title: String = "Invoice PDF currency", labels: [String] = [], assignees: [String] = [],
  state: IssueState = .open, created: String = "2026-11-01T10:00:00Z", updated: String = "2026-11-10T10:00:00Z"
) -> InboxIssue {
  issue(
    "acme/ledger", number, title: title, labels: labels, assignees: assignees, state: state, created: created,
    updated: updated)
}

private func issue(
  _ repo: String, _ number: Int, title: String = "Invoice PDF currency", labels: [String] = [],
  assignees: [String] = [], state: IssueState = .open, created: String = "2026-11-01T10:00:00Z",
  updated: String = "2026-11-10T10:00:00Z"
) -> InboxIssue {
  InboxIssue(
    repo: repo, number: number, title: title, url: "https://github.com/\(repo)/issues/\(number)", state: state,
    labels: labels, assignees: assignees, createdAt: created, updatedAt: updated)
}

/// A work session whose issues are `issues`, in a checkout of `repository`.
private func session(
  _ id: String, repository: String? = "acme/ledger", issues: [SessionIssue]?, pr: PRSummary? = nil
) -> SessionSummary {
  var s = SessionSummary(
    id: id, name: id, cwd: "/tmp/\(id)", repo: nil, branch: nil, claudeSessionId: id, state: .working, reason: "",
    since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [],
    pr: pr)
  s.repository = repository
  s.repositoryRead = true
  s.issues = issues
  return s
}

private func setIssue(_ repo: String?, _ number: Int) -> SessionIssue {
  SessionIssue(
    repo: repo, number: number, via: .set, url: repo.map { "https://github.com/\($0)/issues/\(number)" })
}

private func pr(_ number: Int, repo: String = "acme/ledger", state: PRState) -> PRSummary {
  PRSummary(
    PullRequest(
      id: "PR_\(number)", number: number, url: "https://github.com/\(repo)/pull/\(number)", repo: repo, state: state))
}

/// `owner/name#N` of each issue, in order.
private func refs(_ issues: [InboxIssue]?) -> [String] {
  (issues ?? []).map { "\($0.repo)#\($0.number)" }
}

/// The buckets of the rows that list the issue.
private func bucketsHolding(_ i: InboxIssue, _ listed: [ListedIssue]) -> [IssueBucket] {
  listed.filter { $0.issue.id == i.id }.map(\.bucket)
}

/// A cache after a read of `issues` from `source`.
private func merged(
  _ issues: [InboxIssue], into cache: IssueCache = IssueCache(), source: String = "acme/ledger", full: Bool = false
) -> IssueCache {
  var cache = cache
  cache.merge(issues, source: source, full: full)
  return cache
}

@Suite struct IssueInboxTests {

  // MARK: Buckets

  struct BucketCase: Sendable, CustomTestStringConvertible {
    var name: String
    var labels: [String]
    var assignees: [String]
    var bucket: IssueBucket
    var testDescription: String { name }
  }

  @Test(arguments: [
    BucketCase(name: "assigned to me", labels: [], assignees: ["robin-k"], bucket: .mine),
    BucketCase(name: "me and the team label", labels: ["team/billing"], assignees: ["robin-k"], bucket: .mine),
    BucketCase(name: "me and a teammate", labels: [], assignees: ["ana-m", "robin-k"], bucket: .mine),
    BucketCase(name: "my login in another case", labels: [], assignees: ["Robin-K"], bucket: .mine),
    BucketCase(name: "team label, unassigned", labels: ["team/billing"], assignees: [], bucket: .teamUnassigned),
    BucketCase(name: "team label in another case", labels: ["Team/Billing"], assignees: [], bucket: .teamUnassigned),
    BucketCase(name: "teammate, no team label", labels: [], assignees: ["dev-p"], bucket: .teamAssigned),
    BucketCase(name: "team label, outsider", labels: ["team/billing"], assignees: ["zed-q"], bucket: .teamAssigned),
    BucketCase(name: "outsider, no team label", labels: ["bug"], assignees: ["zed-q"], bucket: .other),
    BucketCase(name: "unassigned, no team label", labels: [], assignees: [], bucket: .other),
    BucketCase(
      name: "a label that only starts with the team's", labels: ["team/billing-ops"], assignees: [], bucket: .other),
  ])
  func eachIssueLandsInOneBucket(_ c: BucketCase) {
    let i = issue(4312, labels: c.labels, assignees: c.assignees)

    let listed = inbox.list([i], sessions: [], marks: [])

    #expect(bucketsHolding(i, listed) == [c.bucket])
  }

  @Test func bucketOfAnIssueMatchesTheBucketThatListsIt() {
    let issues = [
      issue(1, assignees: ["robin-k"]), issue(2, labels: ["team/billing"]), issue(3, assignees: ["kofi-a"]),
      issue(4, assignees: ["zed-q"]),
    ]

    let listed = inbox.list(issues, sessions: [], marks: [])

    for i in issues {
      #expect(bucketsHolding(i, listed) == [inbox.bucket(of: i)], "#\(i.number)")
    }
  }

  @Test func teamWithNoLabelsOrPeopleMakesNoTeamIssues() {
    let lone = IssueInbox(viewer: viewer, team: IssueTeam(labels: [], people: []))
    let i = issue(4312, labels: ["team/billing"], assignees: ["ana-m"])

    #expect(lone.bucket(of: i) == .other)
  }

  // MARK: Hide rule

  @Test func issueThatASessionListsIsBeingWorkedOn() {
    let i = issue(4312, labels: ["team/billing"])
    let s = session("s1", issues: [setIssue("acme/ledger", 4312)])

    let listed = inbox.list([i], sessions: [s], marks: [])

    #expect(bucketsHolding(i, listed) == [.workedOn])
  }

  @Test func beingWorkedOnWinsOverAssignedToMe() {
    let i = issue(4312, assignees: ["robin-k"])
    let s = session("s1", issues: [setIssue("acme/ledger", 4312)])

    let listed = inbox.list([i], sessions: [s], marks: [])

    #expect(bucketsHolding(i, listed) == [.workedOn])
  }

  @Test func removingTheSessionShowsTheIssueAgain() {
    let i = issue(4312, assignees: ["robin-k"])
    let s = session("s1", issues: [setIssue("acme/ledger", 4312)])
    #expect(bucketsHolding(i, inbox.list([i], sessions: [s], marks: [])) == [.workedOn])

    let listed = inbox.list([i], sessions: [], marks: [])

    #expect(bucketsHolding(i, listed) == [.mine])
  }

  @Test func sessionIssueMatchesTheRepoWithoutCase() {
    let i = issue("acme/ledger", 4312)
    let s = session("s1", issues: [setIssue("Acme/Ledger", 4312)])

    #expect(bucketsHolding(i, inbox.list([i], sessions: [s], marks: [])) == [.workedOn])
  }

  @Test func sameNumberInAnotherRepoIsNotHidden() {
    let i = issue("acme/ledger-web", 4312, assignees: ["robin-k"])
    let s = session("s1", issues: [setIssue("acme/ledger", 4312)])

    #expect(bucketsHolding(i, inbox.list([i], sessions: [s], marks: [])) == [.mine])
  }

  /// A branch issue has no repo until the session has a PR. It names an issue in the session's own repository.
  @Test func issueWithNoRepoMatchesTheSessionsRepository() {
    let same = issue("acme/ledger", 4312)
    let other = issue("acme/ledger-web", 4312, assignees: ["robin-k"])
    let s = session(
      "s1", repository: "acme/ledger", issues: [SessionIssue(repo: nil, number: 4312, via: .branch, url: nil)])

    let listed = inbox.list([same, other], sessions: [s], marks: [])

    #expect(bucketsHolding(same, listed) == [.workedOn])
    #expect(bucketsHolding(other, listed) == [.mine])
  }

  @Test func issueWithNoRepoInASessionWithNoRepositoryHidesNothing() {
    let i = issue("acme/ledger", 4312, assignees: ["robin-k"])
    let s = session("s1", repository: nil, issues: [SessionIssue(repo: nil, number: 4312, via: .branch, url: nil)])

    #expect(bucketsHolding(i, inbox.list([i], sessions: [s], marks: [])) == [.mine])
  }

  @Test func sessionWithNoIssuesHidesNothing() {
    let i = issue(4312, assignees: ["robin-k"])
    let s = session("s1", issues: nil)

    #expect(bucketsHolding(i, inbox.list([i], sessions: [s], marks: [])) == [.mine])
  }

  @Test func issueAddressedByAMergedPRStaysHidden() {
    let i = issue(4312, assignees: ["robin-k"])
    let mark = IssueMark(repo: "acme/ledger", number: 4312, pr: 57)

    let listed = inbox.list([i], sessions: [], marks: [mark])

    #expect(bucketsHolding(i, listed) == [])
  }

  @Test func markForAnotherRepoHidesNothing() {
    let i = issue("acme/ledger-web", 4312, assignees: ["robin-k"])
    let mark = IssueMark(repo: "acme/ledger", number: 4312, pr: 57)

    #expect(bucketsHolding(i, inbox.list([i], sessions: [], marks: [mark])) == [.mine])
  }

  // MARK: Merged marks

  @Test func removingASessionWhosePRMergedMarksEachStillOpenIssue() {
    let open = issue(4312)
    let s = session(
      "s1", issues: [setIssue("acme/ledger", 4312), setIssue("acme/ledger", 4400)], pr: pr(57, state: .merged))

    let marks = IssueMark.marks(removing: s, open: [open])

    #expect(marks == [IssueMark(repo: "acme/ledger", number: 4312, pr: 57)])
  }

  @Test(arguments: [PRState.open, .closed])
  func removingASessionWhosePRDidNotMergeMarksNothing(_ state: PRState) {
    let s = session("s1", issues: [setIssue("acme/ledger", 4312)], pr: pr(57, state: state))

    #expect(IssueMark.marks(removing: s, open: [issue(4312)]) == [])
  }

  @Test func removingASessionWithNoPRMarksNothing() {
    let s = session("s1", issues: [setIssue("acme/ledger", 4312)])

    #expect(IssueMark.marks(removing: s, open: [issue(4312)]) == [])
  }

  @Test func markForAnIssueInAnotherRepoNamesThatRepo() {
    let open = issue("acme/ledger-web", 88)
    let s = session("s1", issues: [setIssue("acme/ledger-web", 88)], pr: pr(57, state: .merged))

    #expect(IssueMark.marks(removing: s, open: [open]) == [IssueMark(repo: "acme/ledger-web", number: 88, pr: 57)])
  }

  // MARK: Dismissed

  @Test func dismissedIssueIsHiddenWhileItIsUnchanged() {
    let i = issue(4312, assignees: ["robin-k"])

    let listed = inbox.list([i], sessions: [], dismissed: [i.id: i.updatedAt])

    #expect(bucketsHolding(i, listed) == [])
  }

  @Test func dismissedIssueShowsAgainOnceItChanges() {
    let i = issue(4312, assignees: ["robin-k"], updated: "2026-11-11T10:00:00Z")

    let listed = inbox.list([i], sessions: [], dismissed: [i.id: "2026-11-10T10:00:00Z"])

    #expect(bucketsHolding(i, listed) == [.mine])
  }

  @Test func listNamesTheSessionThatWorksOnTheIssue() {
    let i = issue(4312)
    let s = session("s1", issues: [setIssue("acme/ledger", 4312)])

    let listed = inbox.list([i], sessions: [s])

    #expect(listed == [ListedIssue(issue: i, bucket: .workedOn, session: "s1")])
  }

  @Test func idIsTheLowercasedRepoAndNumber() {
    #expect(issue("Acme/Ledger", 4312).id == "acme/ledger#4312")
  }

  // MARK: Cache merge

  @Test func firstPollStoresTheOpenIssues() {
    let cache = merged([issue(1), issue(2)], full: true)

    #expect(refs(cache.issues).sorted() == ["acme/ledger#1", "acme/ledger#2"])
    #expect(cache.issues.map(\.sources) == [["acme/ledger"], ["acme/ledger"]])
  }

  @Test func updateThatReportsAnIssueClosedRemovesIt() {
    let cache = merged(
      [issue(1, state: .closed, updated: "2026-11-11T10:00:00Z")], into: merged([issue(1), issue(2)], full: true))

    #expect(refs(cache.issues) == ["acme/ledger#2"])
  }

  @Test func closedIssueLeavesTheCacheWhicheverSourceReadIt() {
    let cache = merged([issue(1, state: .closed)], into: merged([issue(1)], full: true), source: "acme label:bug")

    #expect(cache.issues == [])
  }

  @Test func closedIssueForgetsItsDismissalAndItsMark() {
    var cache = merged([issue(1)], full: true)
    cache.dismissed[issue(1).id] = issue(1).updatedAt
    cache.marks = [IssueMark(repo: "acme/ledger", number: 1, pr: 57)]

    cache.merge([issue(1, state: .closed)], source: "acme/ledger", full: false)

    #expect(cache.dismissed == [:])
    #expect(cache.marks == [])
  }

  @Test func updatedOpenIssueReplacesTheOldCopy() {
    let cache = merged(
      [issue(1, title: "New title", assignees: ["ana-m"], updated: "2026-11-11T10:00:00Z")],
      into: merged([issue(1, title: "Old title")], full: true))

    #expect(cache.issues.map(\.title) == ["New title"])
    #expect(cache.issues.first?.assignees == ["ana-m"])
  }

  @Test func closedIssueThatWasNotCachedIsNotAdded() {
    let cache = merged([issue(9, state: .closed)], into: merged([issue(1)], full: true))

    #expect(refs(cache.issues) == ["acme/ledger#1"])
  }

  @Test func sameNumberInTwoReposIsTwoEntries() {
    var cache = merged([issue("acme/ledger", 12), issue("acme/ledger-web", 12)], source: "acme label:bug", full: true)

    cache.merge([issue("acme/ledger-web", 12, state: .closed)], source: "acme label:bug", full: false)

    #expect(refs(cache.issues) == ["acme/ledger#12"])
  }

  @Test func incrementalReadLeavesTheIssuesItDoesNotMentionAlone() {
    let cache = merged([issue(3)], into: merged([issue(1), issue(2)], full: true), full: false)

    #expect(refs(cache.issues).sorted() == ["acme/ledger#1", "acme/ledger#2", "acme/ledger#3"])
  }

  @Test func fullReadDropsTheSourcesIssuesThatItNoLongerReturns() {
    let cache = merged([issue(2)], into: merged([issue(1), issue(2)], full: true), full: true)

    #expect(refs(cache.issues) == ["acme/ledger#2"])
  }

  @Test func fullReadKeepsAnIssueThatAnotherSourceAlsoRead() {
    var cache = merged([issue(1)], full: true)
    cache.merge([issue(1)], source: "acme label:bug", full: true)

    cache.merge([], source: "acme/ledger", full: true)

    #expect(refs(cache.issues) == ["acme/ledger#1"])
    #expect(cache.issues.first?.sources == ["acme label:bug"])
  }

  @Test func issueThatTwoSourcesReadListsBothSources() {
    let cache = merged([issue(1)], into: merged([issue(1)], full: true), source: "acme label:bug", full: true)

    #expect(cache.issues.map(\.sources) == [["acme label:bug", "acme/ledger"]])
  }

  @Test func dropForgetsOnlyTheIssuesNoOtherSourceRead() {
    var cache = merged([issue(1), issue(2)], full: true)
    cache.merge([issue(2)], source: "acme label:bug", full: true)

    cache.drop(source: "acme/ledger")

    #expect(refs(cache.issues) == ["acme/ledger#2"])
  }

  @Test func removeForgetsTheSourcesPollProgress() {
    var cache = merged([issue(1)], full: true)
    cache.polls["acme/ledger"] = IssueSourcePoll(since: "2026-11-12T10:00:00Z", fullAt: 1)
    cache.polls["acme label:bug"] = IssueSourcePoll(since: "2026-11-12T10:00:00Z", fullAt: 1)

    cache.remove(source: "acme/ledger")

    #expect(cache.issues == [])
    #expect(Array(cache.polls.keys) == ["acme label:bug"])
  }

  // MARK: Apply

  /// A poll that started at 100 and read `read` from acme/ledger.
  private func ledgerPoll(_ read: [InboxIssue], full: Bool) -> IssuePoll {
    var poll = IssuePoll(started: 100, ended: 200, since: "new")
    poll.read["acme/ledger"] = read
    if full { poll.full = ["acme/ledger"] }
    return poll
  }

  /// A cache that holds #1 and #2 from acme/ledger, last read in full at 1.
  private func ledgerCache() -> IssueCache {
    var cache = merged([issue(1), issue(2)], full: true)
    cache.polls["acme/ledger"] = IssueSourcePoll(since: "old", fullAt: 1)
    return cache
  }

  @Test func applyOfAFullReadReplacesTheSourcesIssuesAndMovesItsPoll() {
    var cache = ledgerCache()

    cache.apply(ledgerPoll([issue(3)], full: true), sources: ["acme/ledger"])

    #expect(refs(cache.issues) == ["acme/ledger#3"])
    #expect(cache.polls["acme/ledger"] == IssueSourcePoll(since: "new", fullAt: 100))
    #expect(cache.polledAt == 200)
  }

  @Test func applyOfAnIncrementalReadKeepsTheLastFullReadTime() {
    var cache = ledgerCache()

    cache.apply(ledgerPoll([issue(3)], full: false), sources: ["acme/ledger"])

    #expect(refs(cache.issues).sorted() == ["acme/ledger#1", "acme/ledger#2", "acme/ledger#3"])
    #expect(cache.polls["acme/ledger"] == IssueSourcePoll(since: "new", fullAt: 1))
  }

  @Test func applyOfATruncatedFullReadKeepsTheCachedIssuesAndMarksTheSource() {
    var cache = ledgerCache()
    var poll = ledgerPoll([issue(3)], full: true)
    poll.truncated = ["acme/ledger"]

    cache.apply(poll, sources: ["acme/ledger"])

    #expect(refs(cache.issues).sorted() == ["acme/ledger#1", "acme/ledger#2", "acme/ledger#3"])
    #expect(cache.polls["acme/ledger"] == IssueSourcePoll(since: "new", fullAt: 100, truncated: true))
  }

  @Test func applyOfATruncatedIncrementalReadMakesTheNextPollReadInFull() {
    var cache = ledgerCache()
    var poll = ledgerPoll([issue(3)], full: false)
    poll.truncated = ["acme/ledger"]

    cache.apply(poll, sources: ["acme/ledger"])

    #expect(refs(cache.issues).sorted() == ["acme/ledger#1", "acme/ledger#2", "acme/ledger#3"])
    #expect(cache.polls["acme/ledger"] == IssueSourcePoll(since: "old", fullAt: 0))
  }

  @Test func applyOfAPollThatFailedPartwayLeavesTheSourceAlone() {
    var cache = ledgerCache()
    var poll = ledgerPoll([issue(3)], full: true)
    poll.unfinished = ["acme/ledger"]
    poll.error = "timed out"

    cache.apply(poll, sources: ["acme/ledger"])

    #expect(refs(cache.issues).sorted() == ["acme/ledger#1", "acme/ledger#2"])
    #expect(cache.polls["acme/ledger"] == IssueSourcePoll(since: "old", fullAt: 1))
    #expect(cache.polledAt == nil)
    #expect(cache.error == "timed out")
  }

  @Test func applyForgetsASourceThatConfigNoLongerLists() {
    var cache = ledgerCache()

    cache.apply(IssuePoll(started: 100, ended: 200, since: "new"), sources: [])

    #expect(cache.issues == [])
    #expect(cache.polls.isEmpty)
  }

  @Test(arguments: [
    #"Say "hi""#, "Two\nlines", #"Back\slash and \"escaped\""#, "Ünïcode ✓", "", "null",
  ])
  func cacheKeepsEachTitleAcrossAnEncodeAndDecode(_ title: String) throws {
    var cache = IssueCache(viewer: viewer)
    cache.merge([issue(1, title: title)], source: "acme/ledger", full: true)

    let decoded = try JSONCoding.decode(IssueCache.self, from: try JSONCoding.encode(cache))

    #expect(decoded == cache)
  }

  @Test func cacheKeepsAnIssueWithNoLabelsOrAssignees() throws {
    var cache = IssueCache(viewer: viewer)
    cache.merge([issue(1, labels: [], assignees: [])], source: "acme/ledger", full: true)

    let decoded = try JSONCoding.decode(IssueCache.self, from: try JSONCoding.encode(cache))

    #expect(decoded.issues == cache.issues)
  }

  // MARK: Sources

  @Test func orgWithALabelIsASource() throws {
    let source = try IssueSource.parse("acme", label: "team/billing")

    #expect(source == IssueSource(name: "acme", label: "team/billing"))
    #expect(source.isOrg)
  }

  @Test func orgWithAPersonIsASource() throws {
    let source = try IssueSource.parse("acme", person: "ana-m")

    #expect(source == IssueSource(name: "acme", person: "ana-m"))
  }

  @Test func repoNeedsNoFilter() throws {
    let source = try IssueSource.parse("acme/ledger")

    #expect(source == IssueSource(name: "acme/ledger"))
    #expect(!source.isOrg)
  }

  @Test func blankFilterOfARepoIsLeftOut() throws {
    #expect(try IssueSource.parse("acme/ledger", label: "  ", person: "") == IssueSource(name: "acme/ledger"))
  }

  @Test func filtersAreTrimmed() throws {
    #expect(try IssueSource.parse("acme", label: " team/billing ") == IssueSource(name: "acme", label: "team/billing"))
  }

  @Test func keyIsTheLowercasedNameAndTheFilters() {
    #expect(IssueSource(name: "Acme/Ledger").key == "acme/ledger")
    #expect(
      IssueSource(name: "Acme", label: "team/billing", person: "ana-m").key == "acme label:team/billing person:ana-m")
  }

  struct RefusedSource: Sendable, CustomTestStringConvertible {
    var name: String
    var text: String
    var label: String?
    var person: String?
    var testDescription: String { name }
  }

  @Test(arguments: [
    RefusedSource(name: "no filter", text: "acme", label: nil, person: nil),
    RefusedSource(name: "empty label", text: "acme", label: "", person: nil),
    RefusedSource(name: "blank label", text: "acme", label: "  ", person: nil),
    RefusedSource(name: "blank person", text: "acme", label: nil, person: " "),
    RefusedSource(name: "blank label and person", text: "acme", label: "", person: ""),
  ])
  func orgWithoutALabelOrAPersonIsRefused(_ c: RefusedSource) {
    let error = #expect(throws: (any Error).self) {
      try IssueSource.parse(c.text, label: c.label, person: c.person)
    }
    #expect(error.map { "\($0)" }?.contains(IssueSource.orgNeedsFilter) == true)
  }

  @Test func orgNeedsFilterSaysAnOrgNeedsALabelOrAPerson() {
    #expect(IssueSource.orgNeedsFilter == "An org needs a label or a person")
  }

  @Test(arguments: ["acme/", "/ledger", "acme/ledger/extra", "", "a b", "acme/../ledger"])
  func malformedSourceIsRefused(_ text: String) {
    #expect(throws: (any Error).self) { try IssueSource.parse(text, label: "team/billing") }
  }

  // MARK: Count

  /// Two assigned to me (one in another org), one team unassigned, one team assigned to others, and one other.
  private let countIssues = [
    issue("acme/ledger", 1, assignees: ["robin-k"]),
    issue("robin-k/dotkit", 2, assignees: ["robin-k"]),
    issue("acme/ledger-web", 3, labels: ["team/billing"]),
    issue("acme/ledger", 4, assignees: ["dev-p"]),
    issue("acme/ledger", 5, assignees: ["zed-q"]),
  ]

  /// The count that the picker shows under `filter` for the issues that `sb issues` lists.
  private func count(
    _ issues: [InboxIssue], sessions: [SessionSummary] = [], marks: [IssueMark] = [], filter: OrgFilter = OrgFilter()
  ) -> Int {
    IssueList(
      viewer: viewer, issues: inbox.list(issues, sessions: sessions, marks: marks), sources: [], team: team,
      presets: []
    )
    .count(shows: filter.shows(repo:))
  }

  @Test func countIsAssignedToMePlusTeamUnassigned() {
    #expect(count(countIssues) == 3)
  }

  @Test func countLeavesOutIssuesTheOrgFilterHides() {
    #expect(count(countIssues, filter: OrgFilter(keys: ["acme"])) == 2)
  }

  @Test func orgFilterMatchesTheIssuesOwnerWithoutCase() {
    #expect(count([issue("Acme/ledger", 1, assignees: ["robin-k"])], filter: OrgFilter(keys: ["acme"])) == 1)
  }

  @Test func countLeavesOutIssuesBeingWorkedOn() {
    let s = session("s1", issues: [setIssue("acme/ledger", 1)])

    #expect(count(countIssues, sessions: [s]) == 2)
  }

  @Test func countLeavesOutIssuesWithAMergedMark() {
    let mark = IssueMark(repo: "acme/ledger-web", number: 3, pr: 57)

    #expect(count(countIssues, marks: [mark]) == 2)
  }

  @Test(arguments: [OrgFilter(), OrgFilter(keys: ["acme"]), OrgFilter(keys: ["robin-k"])])
  func countEqualsTheMineAndTeamUnassignedBucketsUnderTheSameFilter(_ filter: OrgFilter) {
    let listed = inbox.list(countIssues.filter { filter.shows(repo: $0.repo) }, sessions: [])

    #expect(
      count(countIssues, filter: filter) == listed.filter { $0.bucket == .mine || $0.bucket == .teamUnassigned }.count)
  }

  // MARK: Branch for Start

  @Test func branchIsThePrefixTheNumberAndTheTitlesSlug() {
    let i = issue(4312, title: "Invoice PDF currency")

    #expect(i.branch(prefix: "robin/") == "robin/4312-invoice-pdf-currency")
  }

  @Test func branchWithNoPrefixStartsWithTheNumber() {
    #expect(issue(4312, title: "Invoice PDF currency").branch(prefix: "") == "4312-invoice-pdf-currency")
  }

  @Test func branchCutsALongTitle() {
    let i = issue(4312, title: String(repeating: "invoice currency ", count: 10))

    #expect(i.branch(prefix: "robin/").count <= "robin/4312-".count + 40)
  }

  @Test(arguments: ["…", "", "  --  "])
  func branchOfATitleWithNoSlugIsThePrefixAndTheNumber(_ title: String) {
    #expect(issue(4312, title: title).branch(prefix: "robin/") == "robin/4312")
  }

  /// Start also sets the session's issue, so a title whose slug starts with a digit or has no ASCII letter need not
  /// link through the branch rule. These ordinary titles do.
  @Test(
    arguments: ["Invoice PDF currency", "Ünïcode façade", "  -- leading dashes", "v2 API"],
    ["", "robin/", "team/robin/"])
  func branchRuleReadsTheIssueNumberBackFromTheBranch(_ title: String, _ prefix: String) {
    let branch = issue(4312, title: title).branch(prefix: prefix)

    #expect(Issues.branchNumber(branch, prNumber: nil) == 4312, "\(branch)")
  }

  // MARK: Presets

  @Test func presetReplacesURLWithTheIssuesPage() {
    let preset = IssuePreset(name: "go", prompt: "/go --yolo {url}")

    #expect(preset.prompt(for: issue(4312)) == "/go --yolo https://github.com/acme/ledger/issues/4312")
  }

  @Test func presetReplacesEveryURL() {
    let preset = IssuePreset(name: "twice", prompt: "Read {url}. Then fix {url}.")

    #expect(
      preset.prompt(for: issue(4312))
        == "Read https://github.com/acme/ledger/issues/4312. Then fix https://github.com/acme/ledger/issues/4312.")
  }

  @Test func presetReplacesTheNumberRepoTitleAndBody() {
    var i = issue(4312, title: "Invoice PDF currency")
    i.body = "Totals show USD."
    let preset = IssuePreset(name: "all", prompt: "{repo}#{number}: {title}. {body}")

    #expect(
      preset.prompt(for: i)
        == IssuePreset.untrustedNote
        + "\n\nacme/ledger#4312: <issue-title>Invoice PDF currency</issue-title>. <issue-body>\nTotals show USD.\n</issue-body>"
    )
  }

  @Test(arguments: ["</issue-body>", "</ISSUE-BODY>", "< / issue-body>", "</issue-title>"])
  func aClosingTagInTheIssueTextCanNotEndTheFence(tag: String) {
    var i = issue(4312, title: "Title \(tag) with a tag")
    i.body = "Before\n\(tag)\nAfter"
    let prompt = IssuePreset(name: "all", prompt: "{title} {body}").prompt(for: i)

    #expect(prompt.components(separatedBy: "&lt;" + tag.dropFirst()).count == 3)
    #expect(prompt.components(separatedBy: "</issue-title>").count == 2)
    #expect(prompt.components(separatedBy: "</issue-body>").count == 2)
    #expect(prompt.hasSuffix("After\n</issue-body>"))
  }

  @Test func aPlaceholderInTheIssueTextStaysAsWritten() {
    var i = issue(4312, title: "Use {body} and {url}")
    i.body = "Set {repo} to {title}"
    let prompt = IssuePreset(name: "all", prompt: "{title}|{body}").prompt(for: i)

    #expect(
      prompt == IssuePreset.untrustedNote
        + "\n\n<issue-title>Use {body} and {url}</issue-title>|<issue-body>\nSet {repo} to {title}\n</issue-body>")
  }

  @Test func aPresetWithoutTheTitleOrBodyHasNoNote() {
    let preset = IssuePreset(name: "go", prompt: "/go --yolo {url} {repo}#{number}")

    #expect(preset.prompt(for: issue(4312)) == "/go --yolo https://github.com/acme/ledger/issues/4312 acme/ledger#4312")
  }

  @Test(arguments: ["robin-k", "ROBIN-K", "ana-m", "Kofi-A"])
  func theViewerOrATeammateIsTrusted(author: String) {
    var i = issue(4312)
    i.author = author
    #expect(inbox.trusts(i))
  }

  @Test(arguments: ["zed-q", "team/billing", "", nil] as [String?])
  func anyoneElseIsNotTrusted(author: String?) {
    var i = issue(4312)
    i.author = author
    #expect(!inbox.trusts(i))
  }

  @Test func aViewerThatSbdHasNotReadTrustsOnlyTheTeam() {
    var i = issue(4312)
    i.author = "robin-k"
    #expect(!IssueInbox(viewer: nil, team: team).trusts(i))
    i.author = "ana-m"
    #expect(IssueInbox(viewer: nil, team: team).trusts(i))
  }

  @Test func plainPresetSendsTheTitleTheURLAndTheBody() throws {
    var i = issue(4312, title: "Invoice PDF currency")
    i.body = "Totals show USD."
    let plain = try IssuePreset.named("plain", in: IssuePreset.defaults)

    let prompt = plain.prompt(for: i)

    #expect(prompt.contains("Invoice PDF currency"))
    #expect(prompt.contains("https://github.com/acme/ledger/issues/4312"))
    #expect(prompt.contains("<issue-body>\nTotals show USD.\n</issue-body>"))
    #expect(prompt.hasPrefix(IssuePreset.untrustedNote))
  }

  @Test func defaultsHoldOnlyPlain() {
    #expect(IssuePreset.defaults.map(\.name) == ["plain"])
  }

  @Test func presetIsFoundByName() throws {
    let presets = [IssuePreset(name: "go", prompt: "/go --yolo {url}"), IssuePreset(name: "plain", prompt: "{url}")]

    #expect(try IssuePreset.named("go", in: presets) == presets[0])
  }

  @Test func unknownPresetIsAnErrorThatNamesIt() {
    let presets = [IssuePreset(name: "go", prompt: "/go --yolo {url}")]

    let error = #expect(throws: (any Error).self) { try IssuePreset.named("nope", in: presets) }
    #expect(error.map { "\($0)" }?.contains("nope") == true)
  }

  @Test func presetsComeFromIssuesPresetsInConfig() throws {
    let config = try JSONCoding.decode(
      Config.self, from: #"{"issues": {"presets": [{"name": "go", "prompt": "/go --yolo {url}"}]}}"#)

    #expect(config.issues.presets == [IssuePreset(name: "go", prompt: "/go --yolo {url}")])
    #expect(config.issues.allPresets == [IssuePreset(name: "go", prompt: "/go --yolo {url}")])
  }

  @Test func configWithoutPresetsHasTheDefaults() throws {
    let config = try JSONCoding.decode(Config.self, from: "{}")

    #expect(config.issues.presets == nil)
    #expect(config.issues.allPresets == IssuePreset.defaults)
  }

  @Test func configWithAnEmptyPresetListHasTheDefaults() throws {
    let config = try JSONCoding.decode(Config.self, from: #"{"issues": {"presets": []}}"#)

    #expect(config.issues.allPresets == IssuePreset.defaults)
  }

  @Test func badIssuesSectionKeepsItsDefaultsAndTheRestOfConfig() throws {
    let config = try JSONCoding.decode(
      Config.self, from: #"{"branchPrefix": "x/", "issues": {"presets": [{"name": "go"}]}}"#)

    #expect(config.branchPrefix == "x/")
    #expect(config.issues == IssueSettings())
  }

  @Test func configReadsTheSourcesTeamAndDefaultPreset() throws {
    let config = try JSONCoding.decode(
      Config.self,
      from: #"""
        {"issues": {"sources": [{"name": "acme", "label": "team/billing"}, {"name": "acme/ledger"}],
          "team": {"labels": ["team/billing"], "people": ["ana-m"]}, "defaultPreset": "go"}}
        """#)

    #expect(
      config.issues.sources == [IssueSource(name: "acme", label: "team/billing"), IssueSource(name: "acme/ledger")])
    #expect(config.issues.team == IssueTeam(labels: ["team/billing"], people: ["ana-m"]))
    #expect(config.issues.defaultPreset == "go")
  }

  /// A team with only labels, or only people, is a whole team. A config.json that leaves out one list must not make
  /// sbd ignore the whole file.
  @Test(
    arguments: zip(
      [#"{"labels": ["team/billing"]}"#, #"{"people": ["ana-m"]}"#, "{}"],
      [IssueTeam(labels: ["team/billing"]), IssueTeam(people: ["ana-m"]), IssueTeam()]))
  func teamWithAListLeftOutReadsTheOtherAsEmpty(_ text: String, _ team: IssueTeam) throws {
    let config = try JSONCoding.decode(Config.self, from: #"{"issues": {"team": \#(text)}}"#)

    #expect(config.issues.team == team)
  }

  @Test func defaultsDoNotHardCodeGo() {
    #expect(!IssuePreset.defaults.contains { $0.prompt.contains("/go") })
  }

  // MARK: Sorting

  @Test func updatedSortsNewestFirst() {
    let issues = [
      issue(1, updated: "2026-11-01T00:00:00Z"), issue(2, updated: "2026-11-09T00:00:00Z"),
      issue(3, updated: "2026-11-05T00:00:00Z"),
    ]

    #expect(refs(IssueSort.updated.sorted(issues)) == ["acme/ledger#2", "acme/ledger#3", "acme/ledger#1"])
  }

  /// Oldest is taken as the creation date, oldest first.
  @Test func oldestSortsByCreationOldestFirst() {
    let issues = [
      issue(1, created: "2026-10-05T00:00:00Z", updated: "2026-11-01T00:00:00Z"),
      issue(2, created: "2026-10-01T00:00:00Z", updated: "2026-11-09T00:00:00Z"),
      issue(3, created: "2026-10-09T00:00:00Z", updated: "2026-11-05T00:00:00Z"),
    ]

    #expect(refs(IssueSort.oldest.sorted(issues)) == ["acme/ledger#2", "acme/ledger#1", "acme/ledger#3"])
  }

  @Test func prioritySortsP0ToP3AndUnlabeledLast() {
    let issues = [
      issue(1, labels: ["bug"]), issue(2, labels: ["P2"]), issue(3, labels: ["P0"]), issue(4, labels: ["P3"]),
      issue(5, labels: ["P1"]),
    ]

    #expect(
      refs(IssueSort.priority.sorted(issues))
        == ["acme/ledger#3", "acme/ledger#5", "acme/ledger#2", "acme/ledger#4", "acme/ledger#1"])
  }

  @Test func issueWithTwoPriorityLabelsSortsByTheHigher() {
    let issues = [issue(1, labels: ["P2"]), issue(2, labels: ["P3", "P1"])]

    #expect(refs(IssueSort.priority.sorted(issues)) == ["acme/ledger#2", "acme/ledger#1"])
  }

  @Test func priorityTiesSortByUpdatedNewestFirst() {
    let issues = [
      issue(1, labels: ["P1"], updated: "2026-11-01T00:00:00Z"),
      issue(2, labels: ["P1"], updated: "2026-11-09T00:00:00Z"),
    ]

    #expect(refs(IssueSort.priority.sorted(issues)) == ["acme/ledger#2", "acme/ledger#1"])
  }

  @Test func lowercasePriorityLabelCounts() {
    #expect(issue(1, labels: ["p2"]).priority == 2)
  }

  @Test(arguments: ["P10", "P4", "xP1", "P1x"])
  func labelThatIsNotP0ToP3SortsAsUnlabeled(_ label: String) {
    let issues = [issue(1, labels: [label], updated: "2026-11-09T00:00:00Z"), issue(2, labels: ["P3"])]

    #expect(refs(IssueSort.priority.sorted(issues)) == ["acme/ledger#2", "acme/ledger#1"])
  }
}

// MARK: - GitHub issues query

private let ledgerSource = IssueSource(name: "acme/ledger")
private let billingSource = IssueSource(name: "acme", label: "team/billing")

@Suite struct GitHubIssuesTests {

  // MARK: Query

  @Test func queryReadsTheCostAndTheViewerWithoutAliases() {
    let (query, _) = GitHub.issuesQuery([IssuePageRequest(source: ledgerSource)])

    #expect(query.contains("rateLimit { cost }"))
    #expect(query.contains("viewer { login }"))
    #expect(query.contains("fragment issue on Issue"))
  }

  @Test func fullReadOfARepoAsksForOpenIssuesAHundredAtATime() {
    let (query, variables) = GitHub.issuesQuery([IssuePageRequest(source: ledgerSource)])

    #expect(
      query.contains(
        "r0: repository(owner: $o0, name: $n0) { issues(first: 100, after: $a0, filterBy: {states: [OPEN]}"))
    #expect(!query.contains("since"))
    #expect(variables["o0"] == "acme")
    #expect(variables["n0"] == "ledger")
    #expect(variables["a0"] == .null)
  }

  @Test func incrementalReadOfARepoAsksForUpdatesSinceTwentyFiveAtATime() {
    let request = IssuePageRequest(source: ledgerSource, since: "2026-11-12T10:00:00Z")

    let (query, variables) = GitHub.issuesQuery([request])

    #expect(request.first == 25)
    #expect(query.contains("issues(first: 25, after: $a0, filterBy: {since: $s0}"))
    #expect(query.contains("$s0: DateTime"))
    #expect(!query.contains("states: [OPEN]"))
    #expect(variables["s0"] == "2026-11-12T10:00:00Z")
  }

  @Test func repoSourceFiltersByItsLabelAndPerson() {
    let source = IssueSource(name: "acme/ledger", label: "team/billing", person: "ana-m")

    let (query, variables) = GitHub.issuesQuery([IssuePageRequest(source: source)])

    #expect(query.contains("filterBy: {states: [OPEN], labels: $l0, assignee: $p0}"))
    #expect(query.contains("$l0: [String!]"))
    #expect(query.contains("$p0: String"))
    #expect(variables["l0"] == .array(["team/billing"]))
    #expect(variables["p0"] == "ana-m")
  }

  @Test func incrementalReadOfARepoKeepsItsLabel() {
    let source = IssueSource(name: "acme/ledger", label: "team/billing")

    let (query, _) = GitHub.issuesQuery([IssuePageRequest(source: source, since: "2026-11-12T10:00:00Z")])

    #expect(query.contains("filterBy: {since: $s0, labels: $l0}"))
  }

  @Test func laterPageAsksAfterTheCursor() {
    let (_, variables) = GitHub.issuesQuery([IssuePageRequest(source: ledgerSource, after: "Y3Vyc29yOjI1")])

    #expect(variables["a0"] == "Y3Vyc29yOjI1")
  }

  @Test func orgSourceIsASearchWithItsSearchText() {
    let (query, variables) = GitHub.issuesQuery([
      IssuePageRequest(source: ledgerSource), IssuePageRequest(source: billingSource),
    ])

    #expect(query.contains("o1: search(type: ISSUE, first: 100, after: $a1, query: $q1)"))
    #expect(variables["q1"]?.string == GitHub.searchText(billingSource, since: nil))
  }

  // MARK: Search text

  @Test func searchTextOfALabelReadsOpenIssues() {
    #expect(GitHub.searchText(billingSource, since: nil) == #"org:acme is:issue label:"team/billing" is:open"#)
  }

  @Test func searchTextOfAPersonFiltersByAssignee() {
    #expect(
      GitHub.searchText(IssueSource(name: "acme", person: "ana-m"), since: nil)
        == "org:acme is:issue assignee:ana-m is:open")
  }

  @Test func searchTextSinceATimeReadsEveryStateUpdatedSince() {
    let text = GitHub.searchText(billingSource, since: "2026-11-12T10:00:00Z")

    #expect(text == #"org:acme is:issue label:"team/billing" updated:>=2026-11-12T10:00:00Z"#)
  }

  @Test func searchTextDropsQuotesFromALabel() {
    let text = GitHub.searchText(IssueSource(name: "acme", label: #"say "hi""#), since: nil)

    #expect(text == #"org:acme is:issue label:"say hi" is:open"#)
  }

  // MARK: Parse

  private let node = """
    {"number": 4312, "title": "Invoice PDF currency", "url": "https://github.com/acme/ledger/issues/4312",
     "body": "Totals show USD.", "state": "OPEN", "createdAt": "2026-11-01T10:00:00Z",
     "updatedAt": "2026-11-10T10:00:00Z", "repository": {"nameWithOwner": "acme/ledger"},
     "labels": {"nodes": [{"name": "team/billing"}]}, "assignees": {"nodes": [{"login": "robin-k"}]},
     "author": {"login": "ana-m"}}
    """

  @Test func parseReadsTheViewerAndEachIssue() throws {
    let data = try #require(
      JSON.parse(
        #"{"viewer": {"login": "robin-k"}, "r0": {"issues": {"pageInfo": {"hasNextPage": false, "endCursor": "Mg"}, "nodes": [\#(node)]}}}"#
      ))

    let (viewer, pages) = GitHub.parseIssues(data, [IssuePageRequest(source: ledgerSource)])

    #expect(viewer == "robin-k")
    #expect(
      pages == [
        IssuePage(issues: [
          InboxIssue(
            repo: "acme/ledger", number: 4312, title: "Invoice PDF currency",
            url: "https://github.com/acme/ledger/issues/4312", body: "Totals show USD.", state: .open,
            labels: ["team/billing"], assignees: ["robin-k"], author: "ana-m", createdAt: "2026-11-01T10:00:00Z",
            updatedAt: "2026-11-10T10:00:00Z")
        ])
      ])
  }

  @Test func anIssueWhoseAuthorIsGoneParsesWithNoAuthor() throws {
    let ghost = node.replacingOccurrences(of: #""author": {"login": "ana-m"}"#, with: #""author": null"#)
    let data = try #require(JSON.parse(#"{"o0": {"nodes": [\#(ghost)]}}"#))

    let (_, pages) = GitHub.parseIssues(data, [IssuePageRequest(source: billingSource)])

    #expect(pages.first?.issues.first?.author == nil)
    #expect(pages.first?.issues.count == 1)
  }

  @Test func closedStateParsesAsClosed() throws {
    let closed = node.replacingOccurrences(of: #""OPEN""#, with: #""CLOSED""#)
    let data = try #require(JSON.parse(#"{"o0": {"nodes": [\#(closed)]}}"#))

    let (_, pages) = GitHub.parseIssues(data, [IssuePageRequest(source: billingSource)])

    #expect(pages.first?.issues.map(\.state) == [.closed])
  }

  @Test func hasNextPageGivesTheCursorOfTheNextPage() throws {
    let data = try #require(
      JSON.parse(#"{"o0": {"pageInfo": {"hasNextPage": true, "endCursor": "Y3Vyc29yOjEwMA"}, "nodes": []}}"#))

    let (_, pages) = GitHub.parseIssues(data, [IssuePageRequest(source: billingSource)])

    #expect(pages == [IssuePage(issues: [], next: "Y3Vyc29yOjEwMA")])
  }

  @Test func nullRepositoryGivesAnErrorPage() throws {
    let data = try #require(
      JSON.parse(#"{"r0": null, "r1": {"issues": {"pageInfo": {"hasNextPage": false}, "nodes": [\#(node)]}}}"#))

    let (_, pages) = GitHub.parseIssues(
      data, [IssuePageRequest(source: IssueSource(name: "acme/gone")), IssuePageRequest(source: ledgerSource)])

    #expect(pages.count == 2)
    #expect(pages[0].issues == [])
    #expect(pages[0].error?.contains("acme/gone") == true)
    #expect(pages[1].error == nil)
    #expect(pages[1].issues.map(\.number) == [4312])
  }

  @Test func missingOrgSearchGivesAnErrorPage() throws {
    let data = try #require(JSON.parse(#"{"viewer": {"login": "robin-k"}}"#))

    let (_, pages) = GitHub.parseIssues(data, [IssuePageRequest(source: billingSource)])

    #expect(pages.first?.error?.contains(billingSource.key) == true)
  }

  /// An org search can return a PR, which the issue fragment leaves empty.
  @Test func searchNodeThatIsNotAnIssueIsSkipped() throws {
    let data = try #require(JSON.parse(#"{"o0": {"nodes": [{}, \#(node)]}}"#))

    let (_, pages) = GitHub.parseIssues(data, [IssuePageRequest(source: billingSource)])

    #expect(pages.first?.issues.map(\.number) == [4312])
  }
}
