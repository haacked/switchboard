import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// The session's issues as `sb get --json` shows them.
  func issues(_ id: String) throws -> [SessionIssue]? {
    try JSONCoding.decode(SessionSummary.self, from: try sb("get", "--json", id)).issues
  }

  /// The session's issues as `sb ls --json` shows them.
  func listedIssues(_ id: String) throws -> [SessionIssue]? {
    try JSONCoding.decode([SessionSummary].self, from: try sb("ls", "--json")).first { $0.id == id }?.issues
  }
}

private let posthog = "PostHog/posthog"
/// #122896's head branch.
private let dependentBranch = "haacked/mcp-experiment-condition-ids"
private let refusedRef = #"can't read "nonsense" as an issue. Use 123, #123, owner/name#123, or an issue URL."#

private func body(_ github: FakeGitHub, _ text: String) {
  github.change(122896) { $0["body"] = .string(text) }
}

private let bodyIssues = [
  SessionIssue(repo: posthog, number: 174, via: .body, url: "https://github.com/PostHog/posthog/issues/174"),
  SessionIssue(repo: "PostHog/charts", number: 9, via: .body, url: "https://github.com/PostHog/charts/issues/9"),
]

private let override = [
  SessionIssue(repo: posthog, number: 5, via: .set, url: "https://github.com/PostHog/posthog/issues/5")
]

@Suite(.blocking(timeLimit: .seconds(120))) struct IssueTests {
  /// #122896's session after a poll that read the body's closing refs.
  func sessionWithBodyIssues() throws -> (Instance, SessionSummary) {
    let github = try FakeGitHub()
    body(github, "Fixes #174\r\nCloses PostHog/charts#9\r\n<!-- Fixes #1 -->")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    try sbd.poll()
    try #require(try sbd.issues(s.id) == bodyIssues)
    return (sbd, s)
  }

  @Test func branchIssueShowsBeforeAPRWithoutALink() throws {
    let sbd = try Instance()

    let s = try sbd.session(in: posthog, branch: "haacked/123-fix-cache")

    let expected = [SessionIssue(repo: nil, number: 123, via: .branch, url: nil)]
    #expect(try sbd.issues(s.id) == expected)
    #expect(try sbd.listedIssues(s.id) == expected)
    #expect(try sbd.sb("get", s.id).contains("  issue:   #123 (branch name)\n"))
  }

  @Test func branchWithoutAnIssueNumberHasNoIssues() throws {
    let sbd = try Instance()

    let s = try sbd.session(in: posthog, branch: "release/2026-11-10")

    #expect(try sbd.issues(s.id) == nil)
    #expect(try !sbd.sb("get", s.id).contains("issue:"))
  }

  @Test func bodyIssuesShowInGetAndLs() throws {
    let github = try FakeGitHub()
    body(github, "Fixes #174\r\nCloses PostHog/charts#9\r\n<!-- Fixes #1 -->")
    let sbd = try Instance.withGitHub(github)
    let s = try sbd.session(in: posthog, branch: dependentBranch)
    #expect(try sbd.issues(s.id) == nil)
    let activity = try sbd.get(s.id).lastActivity

    try sbd.poll()

    #expect(try sbd.issues(s.id) == bodyIssues)
    #expect(try sbd.listedIssues(s.id) == bodyIssues)
    let text = try sbd.sb("get", s.id)
    #expect(text.contains("  issue:   #174 (PR body)  https://github.com/PostHog/posthog/issues/174\n"))
    #expect(text.contains("  issue:   PostHog/charts#9 (PR body)  https://github.com/PostHog/charts/issues/9\n"))
    #expect(!text.contains("#1 (PR body)"))
    #expect(try sbd.get(s.id).lastActivity == activity)
  }

  @Test func overrideHidesTheBodysIssues() throws {
    let (sbd, s) = try sessionWithBodyIssues()

    let set = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("issue", s.id, "PostHog/posthog#5", "--json"))

    #expect(set.issues == override)
    #expect(try sbd.issues(s.id) == override)
    #expect(try sbd.listedIssues(s.id) == override)
    #expect(
      try sbd.sb("get", s.id).contains(
        "  issue:   #5 (set with sb issue)  https://github.com/PostHog/posthog/issues/5\n"))
  }

  @Test func overrideSurvivesARestart() throws {
    let (sbd, s) = try sessionWithBodyIssues()
    try sbd.sb("issue", s.id, "PostHog/posthog#5")

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(try sbd.issues(s.id) == override)
  }

  @Test func overrideSurvivesTheNextPoll() throws {
    let (sbd, s) = try sessionWithBodyIssues()
    try sbd.sb("issue", s.id, "PostHog/posthog#5")

    try sbd.poll(all: true)

    #expect(try sbd.issues(s.id) == override)
  }

  @Test func clearBringsBackTheBodysIssues() throws {
    let (sbd, s) = try sessionWithBodyIssues()
    try sbd.sb("issue", s.id, "PostHog/posthog#5")

    let cleared = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("issue", s.id, "--clear", "--json"))

    #expect(cleared.issues == bodyIssues)
    #expect(try sbd.issues(s.id) == bodyIssues)
  }

  @Test func clearAfterARestartStillClears() throws {
    let (sbd, s) = try sessionWithBodyIssues()
    try sbd.sb("issue", s.id, "PostHog/posthog#5")
    sbd.stopSbd()
    try sbd.startSbd()

    try sbd.sb("issue", s.id, "--clear")

    #expect(try sbd.issues(s.id) == bodyIssues)
  }

  @Test(arguments: [
    ("7", SessionIssue(repo: nil, number: 7, via: .set, url: nil)),
    ("#7", SessionIssue(repo: nil, number: 7, via: .set, url: nil)),
    (
      "PostHog/charts#7",
      SessionIssue(repo: "PostHog/charts", number: 7, via: .set, url: "https://github.com/PostHog/charts/issues/7")
    ),
    (
      "https://github.com/PostHog/charts/issues/7",
      SessionIssue(repo: "PostHog/charts", number: 7, via: .set, url: "https://github.com/PostHog/charts/issues/7")
    ),
  ])
  func overrideReadsEachRefForm(_ text: String, _ expected: SessionIssue) throws {
    let sbd = try Instance()
    let s = try sbd.session(in: posthog, branch: "haacked/123-fix-cache")

    try sbd.sb("issue", s.id, text)

    #expect(try sbd.issues(s.id) == [expected])
  }

  @Test func overrideWithoutALinkPrintsNoURL() throws {
    let sbd = try Instance()
    let s = try sbd.session(in: posthog, branch: "haacked/123-fix-cache")

    try sbd.sb("issue", s.id, "5")

    #expect(try sbd.sb("get", s.id).contains("  issue:   #5 (set with sb issue)\n"))
  }

  @Test func refThatIsNotAnIssueIsRefusedAndChangesNothing() throws {
    let (sbd, s) = try sessionWithBodyIssues()

    let r = try sbd.run("issue", s.id, "nonsense")

    #expect(r.status != 0)
    #expect(r.stderr.contains(refusedRef))
    #expect(try sbd.issues(s.id) == bodyIssues)
  }

  @Test func refusedRefLeavesAnEarlierOverride() throws {
    let (sbd, s) = try sessionWithBodyIssues()
    try sbd.sb("issue", s.id, "PostHog/posthog#5")

    for text in ["nonsense", "#0", "https://github.com/PostHog/posthog/pull/5", "a/b/c#1", "#1234567890"] {
      let r = try sbd.run("issue", s.id, text)

      #expect(r.status != 0, "sb issue \(text)")
      #expect(r.stderr.contains("can't read \"\(text)\" as an issue."), "sb issue \(text)")
    }

    #expect(try sbd.issues(s.id) == override)
  }

  @Test(arguments: [[String](), ["5", "--clear"]])
  func commandWithNeitherOrBothOfARefAndClearIsRefused(_ args: [String]) throws {
    let (sbd, s) = try sessionWithBodyIssues()

    let r = try sbd.run(["issue", s.id] + args)

    #expect(r.status != 0)
    #expect(try sbd.issues(s.id) == bodyIssues)
  }

  @Test(arguments: [
    [String: JSON](), ["issue": "5", "clear": true], ["clear": false], ["issue": 5],
  ])
  func requestWithNeitherOrBothOfAnIssueAndClearIsRefused(_ extra: [String: JSON]) throws {
    let (sbd, s) = try sessionWithBodyIssues()
    let args = extra.merging(["session": .string(s.id)]) { $1 }

    #expect(throws: (any Error).self) { try sbd.client.call("issue", args) }
    #expect(try sbd.issues(s.id) == bodyIssues)
  }

  @Test func theManagerHasNoIssuesAndRefusesOne() throws {
    let sbd = try Instance()
    let m = try JSONCoding.decode(SessionSummary.self, from: try sbd.sb("manager", "--json"))
    #expect(m.issues == nil)

    let r = try sbd.run("issue", m.id, "5")

    #expect(r.status != 0)
    #expect(r.stderr.contains("sb issue works only on a work session"))
    #expect(try sbd.issues(m.id) == nil)
  }

  @Test func aFollowupThatHasNotStartedHasNoIssuesAndRefusesOne() throws {
    let sbd = try Instance()
    let f = try JSONCoding.decode(
      SessionSummary.self, from: try sbd.sb("followup", "add", "--json", "--repo", "acme/widgets", "Fix the cache."))
    #expect(f.issues == nil)

    let r = try sbd.run("issue", f.id, "5")

    #expect(r.status != 0)
    #expect(r.stderr.contains("sb issue works only on a work session that has started"))
    #expect(try sbd.issues(f.id) == nil)
  }
}
