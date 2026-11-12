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

private func content(_ s: SessionSummary, activeAccount: String = ClaudeAccount.defaultFolder) -> HoverCardContent {
  HoverCardContent(s, activeAccount: activeAccount, now: now)
}

/// Every string the card shows.
private func texts(_ c: HoverCardContent) -> [String] {
  [c.title] + c.details + [c.pr?.text, c.summary].compactMap { $0 }
}

/// A session with every fact the card can show.
private func everything() -> SessionSummary {
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
  return s
}

@Suite struct HoverCardContentTests {
  @Test func sessionWithOnlyANameGivesTheNameAndActivity() {
    let c = content(bare())

    #expect(c.title == "fix-flag-cache-race")
    #expect(c.details == ["active 42s ago"])
    #expect(c.pr == nil)
    #expect(c.summary == nil)
  }

  @Test func sessionWithEveryFactGivesEachPartInOrder() {
    let c = content(everything())

    #expect(c.title == "fix-flag-cache-race")
    #expect(
      c.details == [
        "PostHog/posthog · haacked/fix-flag-cache-race",
        "Issues #174, PostHog/charts#9",
        "Flags cache rewrite · personal account · active 12m ago",
      ])
    #expect(
      c.pr == HoverCardContent.PRChip(text: "#130488 Review required, checks pending", status: .reviewRequired))
    #expect(c.summary == "Fixed the retry loop and added a test. The tests pass, and the branch is ready to push.")
  }

  @Test func theCardLeavesOutThePRTitle() {
    #expect(!texts(content(everything())).contains { $0.contains("Fix race in flag cache refresh") })
  }

  @Test func theCardLeavesOutTheStateTitle() {
    #expect(!texts(content(everything())).contains { $0.contains("Needs you") })
  }

  @Test func theCardLeavesOutTheOldLinePrefixes() {
    let shown = texts(content(everything()))

    for prefix in ["Summary:", "Last reply:", "Group:", "Account:", "Last activity"] {
      #expect(!shown.contains { $0.contains(prefix) }, "\(prefix)")
    }
  }

  @Suite struct Accessibility {
    @Test func everyPartJoinsInOrder() {
      #expect(
        content(everything()).accessibilityText
          == "fix-flag-cache-race. PostHog/posthog · haacked/fix-flag-cache-race. Issues #174, PostHog/charts#9. "
          + "Flags cache rewrite · personal account · active 12m ago. #130488 Review required, checks pending. "
          + "Fixed the retry loop and added a test. The tests pass, and the branch is ready to push.")
    }

    @Test func missingPartsLeaveNoEmptySentences() {
      #expect(content(bare()).accessibilityText == "fix-flag-cache-race. active 42s ago")
    }

    @Test func chipAndSummaryFollowTheDetails() {
      var s = bare(reason: "waits on CI")
      s.pr = pr()
      s.lastActivity = 0

      #expect(
        content(s).accessibilityText == "fix-flag-cache-race. PostHog/posthog. #130488 Review required. Waits on CI")
    }
  }

  @Suite struct Place {
    @Test func prRepoAndBranchShareALine() {
      var s = bare()
      s.pr = pr()
      s.branch = "haacked/fix"

      #expect(content(s).details.first == "PostHog/posthog · haacked/fix")
    }

    @Test func prRepoWinsOverTheFolder() {
      var s = bare()
      s.pr = pr()
      s.checkout = "/repos/other-checkout"
      s.repo = "/repos/other-repo"
      s.branch = "haacked/fix"

      #expect(content(s).details.first == "PostHog/posthog · haacked/fix")
    }

    @Test func folderNameStandsInForTheRepoWithoutAPR() {
      var s = bare()
      s.repo = "/repos/posthog"
      s.branch = "haacked/fix"

      #expect(content(s).details.first == "posthog · haacked/fix")
    }

    @Test func checkoutStandsInForTheRepoWithoutAPR() {
      var s = bare()
      s.checkout = "/Users/me/dev/switchboard"
      s.branch = "haacked/fix"

      #expect(content(s).details.first == "switchboard · haacked/fix")
    }

    @Test func checkoutWinsOverTheRepoFolder() {
      var s = bare()
      s.checkout = "/Users/me/dev/switchboard"
      s.repo = "/repos/posthog"

      #expect(content(s).details.first == "switchboard")
    }

    @Test func folderNameAloneHasNoSeparator() {
      var s = bare()
      s.repo = "/repos/posthog"

      #expect(content(s).details == ["posthog", "active 42s ago"])
    }

    @Test func branchAloneHasNoSeparator() {
      var s = bare()
      s.branch = "haacked/fix"

      #expect(content(s).details == ["haacked/fix", "active 42s ago"])
    }

    @Test func emptyBranchCountsAsNoBranch() {
      var s = bare()
      s.repo = "/repos/posthog"
      s.branch = ""

      #expect(content(s).details.first == "posthog")
    }

    @Test func branchThatEqualsTheNameIsLeftOutBesideTheRepo() {
      var s = bare(name: "haacked/fix")
      s.repo = "/repos/posthog"
      s.branch = "haacked/fix"

      #expect(content(s).details == ["posthog", "active 42s ago"])
    }

    @Test func branchThatEqualsTheNameWithNoRepoLeavesThePlaceOut() {
      var s = bare(name: "haacked/fix")
      s.branch = "haacked/fix"

      #expect(content(s).details == ["active 42s ago"])
    }

    @Test func branchThatOnlyEndsWithTheNameStillShows() {
      var s = bare(name: "fix")
      s.repo = "/repos/posthog"
      s.branch = "haacked/fix"

      #expect(content(s).details.first == "posthog · haacked/fix")
    }
  }

  @Suite struct PRChipText {
    @Test func noPRGivesNoChip() {
      var s = bare()
      s.repo = "/repos/posthog"
      s.branch = "haacked/fix"

      #expect(content(s).pr == nil)
    }

    @Test(arguments: PRStatus.allCases)
    func chipCarriesTheNumberAndTheStatus(_ status: PRStatus) {
      var s = bare()
      s.pr = pr(status: status)

      #expect(content(s).pr == HoverCardContent.PRChip(text: "#130488 \(status.rawValue)", status: status))
    }

    @Test func checksFollowTheStatusInLowerCase() {
      var s = bare()
      s.pr = pr(checks: "PENDING")

      #expect(content(s).pr?.text == "#130488 Review required, checks pending")
    }

    @Test func mergedPRShowsMerged() {
      var s = bare(state: .done)
      s.pr = pr(state: .merged, status: .merged, checks: "SUCCESS")

      #expect(content(s).pr == HoverCardContent.PRChip(text: "#130488 Merged, checks success", status: .merged))
    }

    @Test func closedPRShowsClosed() {
      var s = bare(state: .done)
      s.pr = pr(state: .closed, status: .closed)

      #expect(content(s).pr == HoverCardContent.PRChip(text: "#130488 Closed", status: .closed))
    }

    @Test func prInTheTrunkQueueShowsItsQueueState() {
      var s = bare()
      s.pr = pr(status: .approved, checks: "SUCCESS", queue: .testing)

      #expect(content(s).pr?.text == "#130488 Approved, checks success, Trunk testing")
    }

    @Test func prInGitHubsMergeQueueShowsIt() {
      var s = bare()
      s.pr = pr(status: .approved)
      s.pr?.inMergeQueue = true

      #expect(content(s).pr?.text == "#130488 Approved, in the merge queue")
    }

    @Test func trunkLoginNeededComesLast() {
      var s = bare()
      s.pr = pr(status: .approved, checks: "SUCCESS", queue: .testing)
      s.pr?.trunkLoginNeeded = true

      #expect(content(s).pr?.text == "#130488 Approved, checks success, Trunk testing; trunk login needed")
    }

    @Test(arguments: [Bool?.none, false])
    func noTrunkLoginNeededLeavesItOut(_ needed: Bool?) {
      var s = bare()
      s.pr = pr(status: .approved)
      s.pr?.trunkLoginNeeded = needed

      #expect(content(s).pr?.text == "#130488 Approved")
    }
  }

  @Suite struct IssuesLine {
    private func issuesLine(_ s: SessionSummary) -> String? {
      content(s).details.first { $0.hasPrefix("Issues") }
    }

    @Test(arguments: [[SessionIssue]?.none, []])
    func noIssuesGiveNoIssuesLine(_ issues: [SessionIssue]?) {
      var s = bare()
      s.pr = pr()
      s.issues = issues

      #expect(issuesLine(s) == nil)
    }

    @Test func oneIssueGivesNoIssuesLine() {
      var s = bare()
      s.pr = pr()
      s.issues = [bodyIssue(174)]

      #expect(issuesLine(s) == nil)
    }

    @Test func twoIssuesInThePRsRepoShowTheirNumbers() {
      var s = bare()
      s.pr = pr()
      s.issues = [bodyIssue(174), bodyIssue(9)]

      #expect(issuesLine(s) == "Issues #174, #9")
    }

    @Test func issueInAnotherRepoShowsItsRepo() {
      var s = bare()
      s.pr = pr()
      s.issues = [bodyIssue(174), bodyIssue(9, "PostHog/charts")]

      #expect(issuesLine(s) == "Issues #174, PostHog/charts#9")
    }

    @Test func branchIssueWithNoRepoShowsItsNumber() {
      var s = bare()
      s.pr = pr()
      s.issues = [branchIssue, bodyIssue(174)]

      #expect(issuesLine(s) == "Issues #123, #174")
    }

    @Test func withoutAPRAnIssueWithARepoShowsItsRepo() {
      var s = bare()
      s.issues = [branchIssue, bodyIssue(174)]

      #expect(issuesLine(s) == "Issues #123, PostHog/posthog#174")
    }

    @Test func issuesLineSitsBetweenThePlaceAndTheActivity() {
      var s = bare()
      s.pr = pr()
      s.issues = [bodyIssue(174), bodyIssue(9)]

      #expect(content(s).details == ["PostHog/posthog", "Issues #174, #9", "active 42s ago"])
    }
  }

  @Suite struct GroupAccountAndActivity {
    /// The last detail line, which holds the group, the account, and the activity.
    private func meta(_ s: SessionSummary, activeAccount: String = ClaudeAccount.defaultFolder) -> String? {
      content(s, activeAccount: activeAccount).details.last
    }

    private func withAccount(_ account: String?) -> SessionSummary {
      var s = bare()
      s.account = account
      return s
    }

    @Test func groupNameJoinsTheActivity() {
      var s = bare()
      s.group = "g1"
      s.groupName = "Flags cache rewrite"

      #expect(content(s).details == ["Flags cache rewrite · active 42s ago"])
    }

    @Test func emptyGroupNameLeavesTheGroupOut() {
      var s = bare()
      s.group = "g1"
      s.groupName = ""

      #expect(content(s).details == ["active 42s ago"])
    }

    @Test func groupAndAccountWithoutActivityHaveNoTrailingSeparator() {
      var s = bare(state: .notStarted)
      s.followup = Followup(prompt: "p")
      s.groupName = "Flags cache rewrite"
      s.account = personalFolder

      #expect(content(s).details == ["Flags cache rewrite · personal account"])
    }

    @Test func noAccountWithTheDefaultActiveLeavesTheAccountOut() {
      #expect(meta(withAccount(nil)) == "active 42s ago")
    }

    @Test func noAccountWithAnotherActiveLeavesTheAccountOut() {
      #expect(meta(withAccount(nil), activeAccount: personalFolder) == "active 42s ago")
    }

    @Test(arguments: [personalFolder, ClaudeAccount.defaultFolder])
    func theActiveAccountLeavesTheAccountOut(_ folder: String) {
      #expect(meta(withAccount(folder), activeAccount: folder) == "active 42s ago")
    }

    @Test func anotherAccountShowsItsShortName() {
      #expect(meta(withAccount(personalFolder)) == "personal account · active 42s ago")
    }

    @Test func theDefaultAccountUnderAnotherActiveShowsDefault() {
      #expect(
        meta(withAccount(ClaudeAccount.defaultFolder), activeAccount: personalFolder)
          == "default account · active 42s ago")
    }

    @Test func folderWithoutTheClaudePrefixShowsItsFolderName() {
      #expect(meta(withAccount("/opt/accounts/work")) == "work account · active 42s ago")
    }

    @Test(arguments: [
      ("~/.claude-personal", personalFolder),
      ("~/.claude-personal/", personalFolder),
      (personalFolder + "/", personalFolder),
      (personalFolder, "~/.claude-personal"),
      (personalFolder, personalFolder + "/"),
      (personalFolder + "/./", "~/.claude-personal"),
    ])
    func sameFolderWrittenAnotherWayLeavesTheAccountOut(_ account: String, _ active: String) {
      #expect(meta(withAccount(account), activeAccount: active) == "active 42s ago")
    }

    @Test(arguments: ["~/.claude", "~/.claude/", NSHomeDirectory() + "/.claude/"])
    func noAccountWithTheDefaultWrittenAnotherWayLeavesTheAccountOut(_ active: String) {
      #expect(meta(withAccount(nil), activeAccount: active) == "active 42s ago")
    }

    @Test(arguments: ["~/.claude", "~/.claude/", NSHomeDirectory() + "/.claude"])
    func defaultAccountWrittenAnotherWayWithTheDefaultActiveLeavesTheAccountOut(_ account: String) {
      #expect(meta(withAccount(account)) == "active 42s ago")
    }

    @Test func otherAccountWrittenWithATildeStillShows() {
      #expect(meta(withAccount("~/.claude-personal/")) == "personal account · active 42s ago")
    }

    @Test(arguments: [
      (42 * second, "42s"), (5 * minute, "5m"), (3 * hour, "3h"), (2 * day, "2d"),
    ])
    func activityShowsHowLongAgo(_ elapsed: Int64, _ text: String) {
      var s = bare()
      s.lastActivity = now - elapsed

      #expect(meta(s) == "active \(text) ago")
    }

    @Test func unstartedFollowupLeavesTheActivityOut() {
      var s = bare(state: .notStarted)
      s.followup = Followup(prompt: "p")
      s.lastActivity = now - 5 * minute

      #expect(content(s).details == [])
    }

    @Test func startedFollowupShowsTheActivity() {
      var s = bare()
      s.followup = Followup(prompt: "p")
      s.followup?.started = now - hour
      s.lastActivity = now - 5 * minute

      #expect(content(s).details == ["active 5m ago"])
    }

    @Test(arguments: [Int64(0), -1])
    func activityTimeAtOrBelowZeroLeavesTheActivityOut(_ lastActivity: Int64) {
      var s = bare()
      s.lastActivity = lastActivity

      #expect(content(s).details == [])
    }

    @Test func usesTheGivenNowAndNotTheClock() {
      var s = bare()
      s.lastActivity = 1000

      let c = HoverCardContent(s, activeAccount: ClaudeAccount.defaultFolder, now: 1000 + 3 * hour)

      #expect(c.details == ["active 3h ago"])
    }

    @Test func defaultNowReadsTheClock() {
      var s = bare()
      s.lastActivity = nowMs() - 2 * hour - 30 * minute

      #expect(HoverCardContent(s, activeAccount: ClaudeAccount.defaultFolder).details == ["active 2h ago"])
    }
  }

  @Suite struct SummaryLine {
    @Test func triageSummaryWinsOverTheReasonAndTheReply() {
      var s = bare(reason: "waits on CI")
      s.triage = summary("Fixed the retry loop.")
      s.lastReply = "A reply."

      #expect(content(s).summary == "Fixed the retry loop.")
    }

    @Test func reasonWinsOverTheReply() {
      var s = bare(reason: "waits on CI")
      s.lastReply = "A reply."

      #expect(content(s).summary == "Waits on CI")
    }

    @Test(arguments: ["", " \n\t\n "])
    func blankTriageSummaryFallsBackToTheReason(_ text: String) {
      var s = bare(reason: "waits on CI")
      s.triage = summary(text)

      #expect(content(s).summary == "Waits on CI")
    }

    @Test(arguments: ["", " \n\t\n "])
    func blankTriageSummaryAndNoReasonFallBackToTheReply(_ text: String) {
      var s = bare()
      s.triage = summary(text)
      s.lastReply = "A reply."

      #expect(content(s).summary == "A reply.")
    }

    @Test func noTriageItemAndNoReasonFallBackToTheReply() {
      var s = bare()
      s.lastReply = "A reply."

      #expect(content(s).summary == "A reply.")
    }

    @Test func replyAfterLongLeadingWhitespaceStillShows() {
      var s = bare()
      s.lastReply = String(repeating: "\n", count: 500) + "Done."

      #expect(content(s).summary == "Done.")
    }

    @Test(arguments: ["", "  \n\n\t "])
    func noReplyLeavesTheSummaryOut(_ reply: String) {
      var s = bare()
      s.lastReply = reply

      #expect(content(s).summary == nil)
    }

    @Test func multiLineReplyIsJoinedIntoOneLine() {
      var s = bare()
      s.lastReply = "First line\n\n  Second line  \nThird line\n"

      #expect(content(s).summary == "First line Second line Third line")
    }

    @Test func multiLineSummaryIsJoinedIntoOneLine() {
      var s = bare()
      s.triage = summary("Fixed it.\nTests pass.")

      #expect(content(s).summary == "Fixed it. Tests pass.")
    }

    @Test func multiLineReasonIsJoinedIntoOneLine() {
      let s = bare(reason: "Waits on CI\n\nand on review")

      #expect(content(s).summary == "Waits on CI and on review")
    }

    @Test func replyOver160CharactersIsCutTo160WithAnEllipsis() {
      var s = bare()
      s.lastReply = String(repeating: "A", count: 200)

      #expect(content(s).summary == String(repeating: "A", count: 159) + "…")
    }

    @Test func replyOfSeveralKBWithNoEarlyLineBreakIsCutTo160() throws {
      var s = bare()
      s.lastReply = String(repeating: "Word ", count: 2000) + "\nlast line"

      let text = try #require(content(s).summary)

      #expect(text.count == 160)
      #expect(text.hasSuffix("…"))
      #expect(text.hasPrefix("Word Word "))
    }

    @Test func summaryOver160CharactersIsCutTo160WithAnEllipsis() {
      var s = bare()
      s.triage = summary(String(repeating: "B", count: 300))

      #expect(content(s).summary == String(repeating: "B", count: 159) + "…")
    }

    @Test func reasonOver160CharactersIsCutTo160WithAnEllipsis() {
      let s = bare(state: .waiting, reason: String(repeating: "C", count: 300))

      #expect(content(s).summary == String(repeating: "C", count: 159) + "…")
    }

    @Test func replyThatStartsWithAMarkdownHeadingKeepsIt() {
      var s = bare()
      s.lastReply = "## Result\nAll green"

      #expect(content(s).summary == "## Result All green")
    }

    @Test(arguments: AttentionState.allCases)
    func reasonHasNoStateTitlePrefix(_ state: AttentionState) {
      #expect(content(bare(state: state, reason: "Waits on CI")).summary == "Waits on CI")
    }

    @Test(arguments: AttentionState.allCases)
    func noReasonAndNoReplyGiveNoSummaryInAnyState(_ state: AttentionState) {
      #expect(content(bare(state: state)).summary == nil)
    }
  }

  @Suite struct Capitalization {
    enum Source: String, CaseIterable, Sendable { case triageSummary, reason, reply }

    private func session(_ text: String, from source: Source) -> SessionSummary {
      var s = bare()
      switch source {
      case .triageSummary: s.triage = summary(text)
      case .reason: s.reason = text
      case .reply: s.lastReply = text
      }
      return s
    }

    @Test(arguments: Source.allCases)
    func firstLetterIsCapitalized(_ source: Source) {
      let s = session("answer: should I also update the docs?", from: source)

      #expect(content(s).summary == "Answer: should I also update the docs?")
    }

    @Test(arguments: Source.allCases)
    func restOfTheTextKeepsItsCase(_ source: Source) {
      let s = session("merge PostHog/posthog#130488 after CI", from: source)

      #expect(content(s).summary == "Merge PostHog/posthog#130488 after CI")
    }
  }

  @Suite struct ShellCommandInTheReason {
    private func summaryOf(_ reason: String) -> String? {
      content(bare(state: .working, reason: reason)).summary
    }

    @Test func commandAtTheStartReadsAsRunningAShellCommand() {
      #expect(
        summaryOf("`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk swift build` (<1 min)")
          == "Running a shell command (<1 min)")
    }

    @Test func commandAloneReadsAsRunningAShellCommand() {
      #expect(summaryOf(Attention.toolSummary("Bash", ["command": "swift build"])) == "Running a shell command")
    }

    @Test func commandAfterAWordReadsAsAShellCommand() {
      let command = Attention.toolSummary("Bash", ["command": "git push"])
      #expect(summaryOf("approve \(command)") == "Approve a shell command")
    }

    @Test func codeSpanInAQuestionStays() {
      #expect(
        summaryOf("answer: should I update `config.yml` too?") == "Answer: should I update `config.yml` too?")
    }

    @Test func unclosedBacktickStays() {
      #expect(summaryOf("`swift build (<1 min)") == "`swift build (<1 min)")
    }

    @Test(arguments: [
      "`bin/test` passes on CI, then run `gh pr merge`",
      "`swift build` green; `deploy` reaches prod",
      "`swift build`",
    ])
    func waitNoteThatStartsWithACodeSpanStays(_ note: String) {
      #expect(content(bare(state: .waiting, reason: note)).summary == Triage.capitalized(note))
    }

    @Test func commandLongerThanTheCutReadsAsAShellCommand() {
      #expect(summaryOf("`" + String(repeating: "x", count: 300) + "` (<1 min)") == "Running a shell command (<1 min)")
    }

    /// Reasons that carry a command, and the command.
    static let commands: [(String, String)] = [
      ("`SDKROOT=/Library/Developer/… swift build` (<1 min)", "SDKROOT"),
      ("`swift build`", "swift build"),
      ("approve `git push`", "git push"),
      ("`git commit -m \"Fix `foo` bar\"` (<1 min)", "foo"),
      ("approve `echo `whoami``", "whoami"),
      ("`" + String(repeating: "secret ", count: 50) + "` (<1 min)", "secret"),
    ]

    @Test(arguments: commands)
    func theCommandNeverShows(_ reason: String, _ command: String) throws {
      let text = try #require(summaryOf(reason))

      #expect(!text.contains("`"))
      #expect(!text.contains(command))
    }

    @Test(arguments: commands)
    func theCommandNeverReachesVoiceOver(_ reason: String, _ command: String) {
      let text = content(bare(reason: reason)).accessibilityText

      #expect(!text.contains("`"))
      #expect(!text.contains(command))
    }

    @Test func aCommandInTheTriageSummaryIsNotTheReasonsToReplace() {
      var s = bare(reason: "approve `git push`")
      s.triage = summary("Pushed the branch.")

      #expect(content(s).summary == "Pushed the branch.")
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

    @Test func managerGivesTheNameActivityAndReply() {
      let c = content(Self.manager())

      #expect(c.title == "Manager")
      #expect(c.details == ["active 5m ago"])
      #expect(c.summary == "Started two sessions.")
    }

    @Test func groupChatGivesTheNameGroupAndActivity() {
      let c = content(Self.groupChat())

      #expect(c.title == "Flags cache rewrite chat")
      #expect(c.details == ["Flags cache rewrite · active 42s ago"])
      #expect(c.summary == nil)
    }

    @Test func docketRowGivesTheNameActivityAndReason() {
      let c = content(Self.docketRow())

      #expect(c.title == "Review PostHog/posthog#1")
      #expect(c.details == ["active 42s ago"])
      #expect(c.summary == "Review requested")
    }

    @Test func unstartedFollowupGivesTheNameAndReason() {
      let c = content(Self.unstartedFollowup())

      #expect(c.title == "update-docs")
      #expect(c.details == [])
      #expect(c.summary == "Manual")
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
