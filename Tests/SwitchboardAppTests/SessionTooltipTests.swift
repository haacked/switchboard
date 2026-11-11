import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

private let now: Int64 = 1_800_000_000_000
private let second: Int64 = 1000
private let minute: Int64 = 60 * second
private let hour: Int64 = 60 * minute
private let day: Int64 = 24 * hour

private let posthog = "PostHog/posthog"
private let personalFolder = NSHomeDirectory() + "/.claude-personal"

/// A work session with no repo, branch, PR, issues, group, reply, or account, that did something 42 s ago.
private func bare(
  name: String = "fix-flag-cache-race", state: AttentionState = .working, reason: String = ""
) -> SessionSummary {
  SessionSummary(
    id: "s1", name: name, cwd: "/worktrees/posthog/fix", repo: nil, branch: nil, claudeSessionId: "c", state: state,
    reason: reason, since: now - hour, lastActivity: now - 42 * second, live: true, claudePid: nil, attached: false,
    lastReply: nil, waits: [], notes: [])
}

private func pr(
  number: Int = 130488, repo: String = posthog, title: String = "", state: PRState = .open,
  status: PRStatus = .reviewRequired, checks: String? = nil, queue: TrunkQueueState? = nil
) -> PRSummary {
  var pr = PRSummary(
    PullRequest(id: "PR_\(number)", number: number, url: "https://github.com/\(repo)/pull/\(number)", repo: repo))
  pr.title = title
  pr.state = state
  pr.status = status
  pr.checks = checks
  pr.queue = queue
  return pr
}

private func bodyIssue(_ number: Int, _ repo: String = posthog) -> SessionIssue {
  SessionIssue(repo: repo, number: number, via: .body, url: "https://github.com/\(repo)/issues/\(number)")
}

private let branchIssue = SessionIssue(repo: nil, number: 123, via: .branch, url: nil)

private func summary(_ text: String) -> TriageItem {
  TriageItem(title: "Pick one", kind: .decision, summary: text, source: .summary)
}

private func lines(
  _ s: SessionSummary, activeAccount: String = ClaudeAccount.defaultFolder
) -> [String] {
  s.tooltip(now: now, activeAccount: activeAccount).split(separator: "\n", omittingEmptySubsequences: false)
    .map(String.init)
}

private func line(_ s: SessionSummary, startingWith prefix: String, activeAccount: String = ClaudeAccount.defaultFolder)
  -> String?
{
  lines(s, activeAccount: activeAccount).first { $0.hasPrefix(prefix) }
}

@Suite struct SessionTooltipTests {
  @Test func sessionWithOnlyANameGivesTheNameStateAndActivity() {
    #expect(lines(bare()) == ["fix-flag-cache-race", "Working", "Last activity 42s ago"])
  }

  @Test func sessionWithEveryFactGivesTheTenLinesInOrder() {
    var s = bare(state: .needsYou, reason: "answer: should I also update the docs?")
    s.checkout = "/repos/posthog"
    s.branch = "haacked/fix-flag-cache-race"
    s.pr = pr(title: "Fix race in flag cache refresh", checks: "PENDING")
    s.issues = [bodyIssue(174), bodyIssue(9, "PostHog/charts")]
    s.triage = summary("Fixed the retry loop and added a test.\nThe tests pass, and the branch is ready to push.")
    s.lastReply = "A longer reply that the summary replaces."
    s.group = "g1"
    s.groupName = "Flags cache rewrite"
    s.account = "~/.claude-personal"
    s.lastActivity = now - 12 * minute

    #expect(
      lines(s) == [
        "fix-flag-cache-race",
        "PostHog/posthog · haacked/fix-flag-cache-race",
        "#130488 Review required, checks pending",
        "Fix race in flag cache refresh",
        "Issues #174, PostHog/charts#9",
        "Needs you: answer: should I also update the docs?",
        "Summary: Fixed the retry loop and added a test. The tests pass, and the branch is ready to push.",
        "Group: Flags cache rewrite",
        "Account: personal",
        "Last activity 12m ago",
      ])
  }

  @Suite struct RepoAndBranch {
    @Test func prRepoAndBranchShareALine() {
      var s = bare()
      s.pr = pr()
      s.branch = "haacked/fix"

      #expect(lines(s)[1] == "PostHog/posthog · haacked/fix")
    }

    @Test func prRepoWinsOverTheFolder() {
      var s = bare()
      s.pr = pr()
      s.checkout = "/repos/other-checkout"
      s.repo = "/repos/other-repo"
      s.branch = "haacked/fix"

      #expect(lines(s)[1] == "PostHog/posthog · haacked/fix")
    }

    @Test func folderNameStandsInForTheRepoWithoutAPR() {
      var s = bare()
      s.repo = "/repos/posthog"
      s.branch = "haacked/fix"

      #expect(lines(s)[1] == "posthog · haacked/fix")
    }

    @Test func checkoutStandsInForTheRepoWithoutAPR() {
      var s = bare()
      s.checkout = "/Users/me/dev/switchboard"
      s.branch = "haacked/fix"

      #expect(lines(s)[1] == "switchboard · haacked/fix")
    }

    @Test func checkoutWinsOverTheRepoFolder() {
      var s = bare()
      s.checkout = "/Users/me/dev/switchboard"
      s.repo = "/repos/posthog"

      #expect(lines(s)[1] == "switchboard")
    }

    @Test func folderNameAloneHasNoSeparator() {
      var s = bare()
      s.repo = "/repos/posthog"

      #expect(lines(s) == ["fix-flag-cache-race", "posthog", "Working", "Last activity 42s ago"])
    }

    @Test func branchAloneHasNoSeparator() {
      var s = bare()
      s.branch = "haacked/fix"

      #expect(lines(s) == ["fix-flag-cache-race", "haacked/fix", "Working", "Last activity 42s ago"])
    }

    @Test func emptyBranchCountsAsNoBranch() {
      var s = bare()
      s.repo = "/repos/posthog"
      s.branch = ""

      #expect(lines(s)[1] == "posthog")
    }
  }

  @Suite struct PullRequestLines {
    @Test func prWithNoChecksLeavesChecksOut() {
      var s = bare()
      s.pr = pr()

      let tooltip = lines(s)

      #expect(tooltip.contains("#130488 Review required"))
      #expect(!tooltip.contains { $0.contains(", checks") })
    }

    @Test func mergedPRShowsMerged() {
      var s = bare(state: .done)
      s.pr = pr(state: .merged, status: .merged, checks: "SUCCESS")

      #expect(lines(s).contains("#130488 Merged, checks success"))
    }

    @Test func closedPRShowsClosed() {
      var s = bare(state: .done)
      s.pr = pr(state: .closed, status: .closed)

      #expect(lines(s).contains("#130488 Closed"))
    }

    @Test func prInTheTrunkQueueShowsItsQueueState() {
      var s = bare()
      s.pr = pr(status: .approved, checks: "SUCCESS", queue: .testing)

      #expect(lines(s).contains("#130488 Approved, checks success, Trunk testing"))
    }

    @Test func titleIsOnItsOwnLineAfterThePRLine() throws {
      var s = bare()
      s.pr = pr(title: "Fix race in flag cache refresh", checks: "PENDING")

      let tooltip = lines(s)
      let index = try #require(tooltip.firstIndex(of: "#130488 Review required, checks pending"))

      #expect(tooltip[index + 1] == "Fix race in flag cache refresh")
    }

    @Test func emptyTitleLeavesNoBlankLine() {
      var s = bare()
      s.pr = pr(title: "")

      #expect(
        lines(s) == [
          "fix-flag-cache-race", "PostHog/posthog", "#130488 Review required", "Working", "Last activity 42s ago",
        ])
    }
  }

  @Suite struct IssueLines {
    @Test(arguments: [[SessionIssue]?.none, []])
    func noIssuesGiveNoIssuesLine(_ issues: [SessionIssue]?) {
      var s = bare()
      s.pr = pr()
      s.issues = issues

      #expect(line(s, startingWith: "Issues") == nil)
    }

    @Test func oneIssueGivesNoIssuesLine() {
      var s = bare()
      s.pr = pr()
      s.issues = [bodyIssue(174)]

      #expect(line(s, startingWith: "Issues") == nil)
    }

    @Test func twoIssuesInThePRsRepoShowTheirNumbers() {
      var s = bare()
      s.pr = pr()
      s.issues = [bodyIssue(174), bodyIssue(9)]

      #expect(line(s, startingWith: "Issues") == "Issues #174, #9")
    }

    @Test func issueInAnotherRepoShowsItsRepo() {
      var s = bare()
      s.pr = pr()
      s.issues = [bodyIssue(174), bodyIssue(9, "PostHog/charts")]

      #expect(line(s, startingWith: "Issues") == "Issues #174, PostHog/charts#9")
    }

    @Test func branchIssueWithNoRepoShowsItsNumber() {
      var s = bare()
      s.pr = pr()
      s.issues = [branchIssue, bodyIssue(174)]

      #expect(line(s, startingWith: "Issues") == "Issues #123, #174")
    }

    @Test func withoutAPRAnIssueWithARepoShowsItsRepo() {
      var s = bare()
      s.issues = [branchIssue, bodyIssue(174)]

      #expect(line(s, startingWith: "Issues") == "Issues #123, PostHog/posthog#174")
    }
  }

  @Suite struct StateLine {
    @Test func reasonFollowsTheStateTitle() {
      let s = bare(state: .needsYou, reason: "answer: should I also update the docs?")

      #expect(lines(s).contains("Needs you: answer: should I also update the docs?"))
    }

    @Test(arguments: [
      (AttentionState.needsYou, "Needs you"), (.canContinue, "Claude can continue"),
      (.done, "Done"),
    ])
    func emptyReasonGivesOnlyTheTitle(_ state: AttentionState, _ title: String) {
      #expect(lines(bare(state: state, reason: "")) == ["fix-flag-cache-race", title, "Last activity 42s ago"])
    }

    @Test func reasonIsNotCut() {
      let reason = Array(repeating: "waits on the build", count: 20).joined(separator: " ")
      let s = bare(state: .waiting, reason: reason)

      #expect(lines(s).contains("Waiting: \(reason)"))
    }
  }

  @Suite struct SummaryAndReply {
    private let replyPrefix = "Last reply: "

    @Test func summaryWinsOverTheReply() {
      var s = bare()
      s.triage = summary("Fixed the retry loop.")
      s.lastReply = "A reply."

      let tooltip = lines(s)

      #expect(tooltip.contains("Summary: Fixed the retry loop."))
      #expect(!tooltip.contains { $0.hasPrefix(replyPrefix) })
    }

    @Test func emptySummaryFallsBackToTheReply() {
      var s = bare()
      s.triage = summary("")
      s.lastReply = "A reply."

      let tooltip = lines(s)

      #expect(tooltip.contains("Last reply: A reply."))
      #expect(!tooltip.contains { $0.hasPrefix("Summary") })
    }

    @Test func noTriageItemFallsBackToTheReply() {
      var s = bare()
      s.lastReply = "A reply."

      #expect(lines(s).contains("Last reply: A reply."))
    }

    @Test func blankSummaryFallsBackToTheReply() {
      var s = bare()
      s.triage = summary(" \n\t\n ")
      s.lastReply = "A reply."

      let tooltip = lines(s)

      #expect(tooltip.contains("Last reply: A reply."))
      #expect(!tooltip.contains { $0.hasPrefix("Summary") })
    }

    @Test func replyAfterLongLeadingWhitespaceStillShows() {
      var s = bare()
      s.lastReply = String(repeating: "\n", count: 500) + "Done."

      #expect(lines(s).contains("Last reply: Done."))
    }

    @Test(arguments: ["", "  \n\n\t "])
    func noReplyLeavesTheLineOut(_ reply: String) {
      var s = bare()
      s.lastReply = reply

      #expect(lines(s) == ["fix-flag-cache-race", "Working", "Last activity 42s ago"])
    }

    @Test func multiLineReplyIsJoinedIntoOneLine() {
      var s = bare()
      s.lastReply = "First line\n\n  Second line  \nThird line\n"

      #expect(lines(s).contains("Last reply: First line Second line Third line"))
    }

    @Test func replyOver160CharactersIsCutTo160WithAnEllipsis() throws {
      var s = bare()
      s.lastReply = String(repeating: "a", count: 200)

      let text = try #require(line(s, startingWith: replyPrefix)).dropFirst(replyPrefix.count)

      #expect(text == String(repeating: "a", count: 159) + "…")
    }

    @Test func replyOfSeveralKBWithNoEarlyLineBreakIsCutTo160() throws {
      var s = bare()
      s.lastReply = String(repeating: "word ", count: 2000) + "\nlast line"

      let text = try #require(line(s, startingWith: replyPrefix)).dropFirst(replyPrefix.count)

      #expect(text.count == 160)
      #expect(text.hasSuffix("…"))
      #expect(text.hasPrefix("word word "))
    }

    @Test func replyThatStartsWithAMarkdownHeadingKeepsIt() {
      var s = bare()
      s.lastReply = "## Result\nAll green"

      #expect(lines(s).contains("Last reply: ## Result All green"))
    }

    @Test func summaryOver160CharactersIsCutTo160WithAnEllipsis() throws {
      var s = bare()
      s.triage = summary(String(repeating: "b", count: 300))

      let text = try #require(line(s, startingWith: "Summary: ")).dropFirst("Summary: ".count)

      #expect(text == String(repeating: "b", count: 159) + "…")
    }

    @Test func multiLineSummaryIsJoinedIntoOneLine() {
      var s = bare()
      s.triage = summary("Fixed it.\nTests pass.")

      #expect(lines(s).contains("Summary: Fixed it. Tests pass."))
    }
  }

  @Suite struct GroupLine {
    @Test func groupNameShows() {
      var s = bare()
      s.group = "g1"
      s.groupName = "Flags cache rewrite"

      #expect(line(s, startingWith: "Group") == "Group: Flags cache rewrite")
    }

    @Test func emptyGroupNameLeavesTheLineOut() {
      var s = bare()
      s.group = "g1"
      s.groupName = ""

      #expect(line(s, startingWith: "Group") == nil)
    }
  }

  @Suite struct AccountLine {
    private func accountLine(_ account: String?, active: String) -> String? {
      var s = bare()
      s.account = account
      return line(s, startingWith: "Account", activeAccount: active)
    }

    @Test func noAccountWithTheDefaultActiveLeavesTheLineOut() {
      #expect(accountLine(nil, active: ClaudeAccount.defaultFolder) == nil)
    }

    @Test func noAccountWithAnotherActiveShowsDefault() {
      #expect(accountLine(nil, active: personalFolder) == "Account: default")
    }

    @Test(arguments: [personalFolder, ClaudeAccount.defaultFolder])
    func theActiveAccountLeavesTheLineOut(_ folder: String) {
      #expect(accountLine(folder, active: folder) == nil)
    }

    @Test func anotherAccountShowsItsShortName() {
      #expect(accountLine(personalFolder, active: ClaudeAccount.defaultFolder) == "Account: personal")
    }

    @Test func folderWithoutTheClaudePrefixShowsItsFolderName() {
      #expect(accountLine("/opt/accounts/work", active: ClaudeAccount.defaultFolder) == "Account: work")
    }

    @Test(arguments: [
      ("~/.claude-personal", personalFolder),
      ("~/.claude-personal/", personalFolder),
      (personalFolder + "/", personalFolder),
      (personalFolder, "~/.claude-personal"),
      (personalFolder, personalFolder + "/"),
      (personalFolder + "/./", "~/.claude-personal"),
    ])
    func sameFolderWrittenAnotherWayLeavesTheLineOut(_ account: String, _ active: String) {
      #expect(accountLine(account, active: active) == nil)
    }

    @Test(arguments: ["~/.claude", "~/.claude/", NSHomeDirectory() + "/.claude/"])
    func noAccountWithTheDefaultWrittenAnotherWayLeavesTheLineOut(_ active: String) {
      #expect(accountLine(nil, active: active) == nil)
    }

    @Test(arguments: ["~/.claude", "~/.claude/", NSHomeDirectory() + "/.claude"])
    func defaultAccountWrittenAnotherWayWithTheDefaultActiveLeavesTheLineOut(_ account: String) {
      #expect(accountLine(account, active: ClaudeAccount.defaultFolder) == nil)
    }

    @Test func otherAccountWrittenWithATildeStillShows() {
      #expect(accountLine("~/.claude-personal/", active: ClaudeAccount.defaultFolder) == "Account: personal")
    }
  }

  @Suite struct ActivityLine {
    @Test(arguments: [
      (42 * second, "42s"), (5 * minute, "5m"), (3 * hour, "3h"), (2 * day, "2d"),
    ])
    func showsHowLongAgo(_ elapsed: Int64, _ text: String) {
      var s = bare()
      s.lastActivity = now - elapsed

      #expect(lines(s).last == "Last activity \(text) ago")
    }

    @Test func unstartedFollowupLeavesTheLineOut() {
      var s = bare(state: .notStarted)
      s.followup = Followup(prompt: "p")
      s.lastActivity = now - 5 * minute

      #expect(line(s, startingWith: "Last activity") == nil)
    }

    @Test func startedFollowupShowsTheLine() {
      var s = bare()
      s.followup = Followup(prompt: "p")
      s.followup?.started = now - hour
      s.lastActivity = now - 5 * minute

      #expect(line(s, startingWith: "Last activity") == "Last activity 5m ago")
    }

    @Test(arguments: [Int64(0), -1])
    func activityTimeAtOrBelowZeroLeavesTheLineOut(_ lastActivity: Int64) {
      var s = bare()
      s.lastActivity = lastActivity

      #expect(line(s, startingWith: "Last activity") == nil)
    }

    @Test func usesTheGivenNowAndNotTheClock() {
      var s = bare()
      s.lastActivity = 1000
      let tooltip = s.tooltip(now: 1000 + 3 * hour, activeAccount: ClaudeAccount.defaultFolder)

      #expect(tooltip.hasSuffix("\nLast activity 3h ago"))
    }
  }

  @Suite struct SessionKinds {
    private static func manager() -> SessionSummary {
      var s = bare(name: "Manager", state: .canContinue)
      s.manager = true
      s.kind = .manager
      s.cwd = NSHomeDirectory()
      s.lastReply = "Started two sessions."
      s.lastActivity = now - 5 * minute
      return s
    }

    private static func groupChat() -> SessionSummary {
      var s = bare(name: "Flags cache rewrite chat", state: .waiting)
      s.kind = .chat
      s.chat = "g1"
      s.group = "g1"
      s.groupName = "Flags cache rewrite"
      return s
    }

    private static func docketRow() -> SessionSummary {
      var s = bare(name: "Review PostHog/posthog#1", state: .needsYou, reason: "review requested")
      s.cwd = ""
      s.live = false
      return s
    }

    private static func unstartedFollowup() -> SessionSummary {
      var s = bare(name: "update-docs", state: .notStarted, reason: "manual")
      s.cwd = ""
      s.live = false
      s.followup = Followup(prompt: "Update the docs", repository: posthog)
      s.lastActivity = now - day
      return s
    }

    @Test func managerGivesTheNameStateReplyAndActivity() {
      #expect(
        lines(Self.manager()) == [
          "Manager", "Claude can continue", "Last reply: Started two sessions.", "Last activity 5m ago",
        ])
    }

    @Test func groupChatGivesTheNameStateGroupAndActivity() {
      #expect(
        lines(Self.groupChat()) == [
          "Flags cache rewrite chat", "Waiting", "Group: Flags cache rewrite", "Last activity 42s ago",
        ])
    }

    @Test func docketRowGivesTheNameStateAndActivity() {
      #expect(
        lines(Self.docketRow()) == [
          "Review PostHog/posthog#1", "Needs you: review requested", "Last activity 42s ago",
        ])
    }

    @Test func unstartedFollowupGivesTheNameAndState() {
      #expect(lines(Self.unstartedFollowup()) == ["update-docs", "Not started: manual"])
    }

    @Test(arguments: ["manager", "groupChat", "docketRow", "unstartedFollowup"])
    func everyKindHasNoEmptyLabel(_ kind: String) {
      let s =
        switch kind {
        case "manager": Self.manager()
        case "groupChat": Self.groupChat()
        case "docketRow": Self.docketRow()
        default: Self.unstartedFollowup()
        }

      let tooltip = lines(s)

      #expect(!tooltip.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
      #expect(!tooltip.contains { $0.hasSuffix(":") || $0.hasSuffix(": ") })
      #expect(!tooltip.contains { $0.hasPrefix("·") || $0.hasSuffix("·") || $0.hasPrefix(" ") || $0.hasSuffix(" ") })
    }
  }

  @Suite struct Ago {
    @Test(arguments: [
      (Int64(0), "0s"),
      (59 * second, "59s"),
      (60 * second, "1m"),
      (3599 * second, "59m"),
      (3600 * second, "1h"),
      (86399 * second, "23h"),
      (86400 * second, "1d"),
      (10 * day, "10d"),
    ])
    func bandBoundaries(_ elapsed: Int64, _ text: String) {
      #expect(ago(now - elapsed, now: now) == text)
    }

    @Test func partialSecondsRoundDown() {
      #expect(ago(now - 59_999, now: now) == "59s")
    }

    @Test(arguments: [Int64(1), second, day])
    func futureTimestampClampsToZeroSeconds(_ ahead: Int64) {
      #expect(ago(now + ahead, now: now) == "0s")
    }

    @Test func defaultNowReadsTheClock() {
      #expect(ago(nowMs() - 2 * hour - 30 * minute) == "2h")
    }
  }
}
