import Foundation
import Testing

@testable import SwitchboardCore

/// The one place that builds a `Pause`, so that the tests follow its initializer.
func pauseOf(
  by: Author = .you, from: Pause.Pauser? = nil, reason: String? = nil, since: Int64 = 1_000, until: Wait? = nil,
  message: String? = nil
) -> Pause {
  Pause(by: by, from: from, reason: reason, since: since, until: until, message: message)
}

let managerPauser = Pause.Pauser(id: "m1", name: "Manager", kind: .manager)
/// A chat's pauser names its group.
let flagsChatPauser = Pause.Pauser(id: "c1", name: "Flags", kind: .chat)
let workPauser = Pause.Pauser(id: "k3x9p", name: "flag-cache", kind: .work)

/// `session()` with the pause.
func pausedSession(_ pause: Pause = pauseOf(), done: Bool = false, waits: [Wait]? = nil) -> Session {
  var s = session(done: done)
  s.waits = waits
  s.pause = pause
  return s
}

private let mergeCondition = Wait(id: "w9", kind: .merge, pr: Wait.PullRequest(number: 123), created: 0)
private let sessionCondition = Wait(
  id: "w9", kind: .session, session: Wait.SessionTarget(id: "k3x9p", name: "flag-cache"), state: .done, created: 0)
private let nineAM = epochMs(2026, 11, 15, 9, 0, zone: .current)
private let dateCondition = Wait(id: "w9", kind: .date, until: nineAM, created: 0)

/// The suites nest under one name, so `--filter PauseCoreTests` runs them all.
@Suite struct PauseCoreTests {}

extension PauseCoreTests {
  @Suite struct ByText {
    @Test(arguments: [nil, managerPauser, flagsChatPauser, workPauser] as [Pause.Pauser?])
    func theUserIsYouWhateverTheSession(_ from: Pause.Pauser?) {
      #expect(pauseOf(by: .you, from: from).byText == "you")
    }

    @Test func claudeInTheManagerIsManager() {
      #expect(pauseOf(by: .claude, from: managerPauser).byText == "Manager")
    }

    @Test func claudeInAGroupChatIsThatGroupsChat() {
      #expect(pauseOf(by: .claude, from: flagsChatPauser).byText == "the Flags chat")
    }

    /// A conversation with its own name reads as `Triage.inboxName` names it.
    @Test func claudeInAGroupChatWithItsOwnNameIsTheGroupsChatAndThatName() {
      let billing = Pause.Pauser(id: "c2", name: "Flags", kind: .chat, conversation: "Billing")

      #expect(pauseOf(by: .claude, from: billing).byText == "the Flags chat: Billing")
    }

    /// A pause that an sbd from before several conversations per group stored has no `conversation` key.
    @Test func aStoredChatPauserWithNoConversationIsTheGroupsChat() throws {
      let stored: JSON = ["by": "claude", "from": ["id": "c1", "name": "Flags", "kind": "chat"], "since": 42]

      let pause = try JSONCoding.convert(stored, to: Pause.self)

      #expect(pause.from?.conversation == nil)
      #expect(pause.byText == "the Flags chat")
    }

    @Test func claudeInAWorkSessionIsThatSessionsName() {
      #expect(pauseOf(by: .claude, from: workPauser).byText == "flag-cache")
    }

    @Test func claudeWithNoSessionIsClaude() {
      #expect(pauseOf(by: .claude, from: nil).byText == "Claude")
    }
  }
}

extension PauseCoreTests {
  @Suite struct Line {
    @Test func withoutAReasonOrAConditionNamesWhoPaused() {
      #expect(pauseOf().line == "Paused by you")
    }

    @Test func aReasonFollowsAColon() {
      #expect(
        pauseOf(by: .claude, from: managerPauser, reason: "free CPU for flags").line
          == "Paused by Manager: free CPU for flags")
    }

    @Test(arguments: [
      (mergeCondition, "#123 merges"), (sessionCondition, "flag-cache reaches Done"),
      (dateCondition, "at 2026-11-15 09:00"),
    ])
    func aConditionSaysWhenItResumes(_ until: Wait, _ phrase: String) {
      #expect(pauseOf(until: until).line == "Paused by you; resumes when \(phrase)")
    }

    @Test func aReasonComesBeforeTheCondition() {
      #expect(
        pauseOf(reason: "wait for the fix", until: mergeCondition).line
          == "Paused by you: wait for the fix; resumes when #123 merges")
    }

    @Test func aSessionConditionNamesTheStateItWaitsFor() {
      var until = sessionCondition
      until.state = .readyToMerge

      #expect(pauseOf(until: until).line == "Paused by you; resumes when flag-cache reaches Ready to merge")
    }
  }
}

extension PauseCoreTests {
  @Suite struct ResumeText {
    @Test func theOverrideIsSentVerbatim() {
      let p = pauseOf(reason: "free CPU", message: "stored")

      #expect(p.resumeText(outcome: "#123 merged", override: "  go on\n") == "  go on\n")
    }

    @Test func theStoredMessageIsSentVerbatimWithoutAnOverride() {
      let p = pauseOf(reason: "free CPU", message: "Rebase on main, then continue.")

      #expect(p.resumeText(outcome: "#123 merged", override: nil) == "Rebase on main, then continue.")
    }

    @Test func theDefaultNamesWhoPaused() {
      #expect(
        pauseOf().resumeText(outcome: nil, override: nil)
          == "Switchboard: You were paused by you. Continue where you left off.")
    }

    @Test func theDefaultAddsTheReasonInParentheses() {
      let p = pauseOf(by: .claude, from: managerPauser, reason: "free CPU for flags")

      #expect(
        p.resumeText(outcome: nil, override: nil)
          == "Switchboard: You were paused by Manager (free CPU for flags). Continue where you left off.")
    }

    @Test func theDefaultSaysWhyItResumes() {
      let p = pauseOf(until: mergeCondition)

      #expect(
        p.resumeText(outcome: "#123 merged", override: nil)
          == "Switchboard: You were paused by you. You resume because #123 merged. Continue where you left off.")
    }

    @Test func theDefaultHasTheReasonAndTheOutcome() {
      let p = pauseOf(by: .claude, from: workPauser, reason: "wait for the fix", until: mergeCondition)

      #expect(
        p.resumeText(outcome: "#123 merged", override: nil)
          == "Switchboard: You were paused by flag-cache (wait for the fix). You resume because #123 merged. "
          + "Continue where you left off.")
    }
  }
}

extension PauseCoreTests {
  @Suite struct Blocker {
    @Test func aSessionThatIsNotPausedHasNone() {
      #expect(Pause.blocker(session()) == nil)
    }

    @Test(arguments: [
      (pauseOf(), "paused by you"), (pauseOf(by: .claude, from: managerPauser), "paused by Manager"),
      (pauseOf(by: .claude, from: flagsChatPauser), "paused by the Flags chat"),
      (pauseOf(by: .claude, from: workPauser), "paused by flag-cache"), (pauseOf(by: .claude), "paused by Claude"),
    ])
    func aPausedSessionNamesWhoPausedIt(_ pause: Pause, _ text: String) {
      #expect(Pause.blocker(pausedSession(pause)) == text)
    }

    @Test func aPausedSessionMarkedDoneStillHasOne() {
      #expect(Pause.blocker(pausedSession(done: true)) == "paused by you")
    }
  }
}

extension PauseCoreTests {
  @Suite struct Storage {
    @Test func aSessionThatAnOlderSbdStoredDecodesWithNoPause() throws {
      var stored = try #require(try JSON(encoding: session()).object)
      stored["pause"] = nil

      let decoded = try JSONCoding.convert(JSON.object(stored), to: Session.self)

      #expect(decoded.pause == nil)
    }

    @Test(arguments: [
      pauseOf(),
      pauseOf(by: .claude, from: flagsChatPauser, reason: "free CPU", since: 42, until: mergeCondition, message: "go"),
      pauseOf(by: .claude, from: workPauser, until: sessionCondition),
      pauseOf(by: .claude, until: dateCondition),
    ])
    func aPausedSessionRoundTrips(_ pause: Pause) throws {
      let s = pausedSession(pause)

      let decoded = try JSONCoding.decode(Session.self, from: try JSONCoding.encode(s))

      #expect(decoded == s)
      #expect(decoded.pause == pause)
    }

    @Test func aSessionThatIsNotPausedEncodesNoPauseKey() throws {
      #expect(try JSON(encoding: session())["pause"] == nil)
    }

    @Test func aPauseEncodesWhoPausedByTheirWireNames() throws {
      let json = try JSON(encoding: pauseOf(by: .claude, from: flagsChatPauser))

      #expect(json["by"] == "claude")
      #expect(json["from"]?["id"] == "c1")
      #expect(json["from"]?["name"] == "Flags")
      #expect(json["from"]?["kind"] == "chat")
    }
  }
}

/// The time that the `parseUntil` tests read their conditions at.
private let parseNow = epochMs(2026, 11, 14, 12, 0, zone: .current)
private let hourMs: Int64 = 3_600_000

extension PauseCoreTests {
  @Suite struct ParseUntil {
    /// The condition that a pause of `waiter` builds from the text. A session ref finds a session whose id and name
    /// are the ref, so every refusal comes from the parser or from `makeWait`, never from the lookup.
    func condition(_ text: String, waiter: String = "s1") throws -> Wait {
      try Pause.parseUntil(text, now: parseNow).makeWait(id: "w1", waiter: waiter, now: parseNow) { ref in
        Wait.SessionTarget(id: ref, name: ref)
      }
    }

    @Test(arguments: [("2h", 2 * hourMs), ("30m", 30 * 60_000), ("1d", 24 * hourMs)] as [(String, Int64)])
    func aDurationIsADateThatLongFromNow(_ text: String, _ ms: Int64) throws {
      let wait = try condition(text)

      #expect(wait.kind == .date)
      #expect(wait.until == parseNow + ms)
    }

    @Test(arguments: [
      ("2026-11-15 09:00", epochMs(2026, 11, 15, 9, 0, zone: .current)),
      ("2026-11-15T09:00", epochMs(2026, 11, 15, 9, 0, zone: .current)),
      ("2026-11-15T09:00:00Z", epochMs(2026, 11, 15, 9, 0, zone: .gmt)),
      ("2026-11-15", epochMs(2026, 11, 15, zone: .current)),
    ])
    func aTimeIsADate(_ text: String, _ at: Int64) throws {
      let wait = try condition(text)

      #expect(wait.kind == .date)
      #expect(wait.until == at)
    }

    @Test(arguments: [
      ("#123", Wait.PullRequest(number: 123)), ("pr:123", Wait.PullRequest(number: 123)),
      ("pr:#123", Wait.PullRequest(number: 123)),
      ("owner/name#123", Wait.PullRequest(repository: "owner/name", number: 123)),
      ("pr:owner/name#123", Wait.PullRequest(repository: "owner/name", number: 123)),
      ("https://github.com/owner/name/pull/123", Wait.PullRequest(repository: "owner/name", number: 123)),
      ("https://github.com/owner/name/pull/123/files", Wait.PullRequest(repository: "owner/name", number: 123)),
    ])
    func aPRIsAMergeCondition(_ text: String, _ pr: Wait.PullRequest) throws {
      let wait = try condition(text)

      #expect(wait.kind == .merge)
      #expect(wait.pr == pr)
    }

    /// A PR without a repository means the paused session's repository, so the condition keeps the repository nil
    /// rather than leaving out the PR, which would mean the session's own PR.
    @Test func aPRWithoutARepositoryKeepsItsNumber() throws {
      let wait = try condition("#123")

      #expect(wait.pr?.repository == nil)
      #expect(wait.pr?.number == 123)
    }

    @Test func aSessionWaitsForDoneByDefault() throws {
      var looked: [String] = []

      let wait = try Pause.parseUntil("session:fix-cache", now: parseNow).makeWait(
        id: "w1", waiter: "s1", now: parseNow
      ) { ref in
        looked.append(ref)
        return Wait.SessionTarget(id: "k3x9p", name: "fix-cache")
      }

      #expect(looked == ["fix-cache"])
      #expect(wait.kind == .session)
      #expect(wait.session == Wait.SessionTarget(id: "k3x9p", name: "fix-cache"))
      #expect(wait.state == .done)
    }

    @Test(arguments: [
      ("session:fix-cache=needs_you", AttentionState.needsYou), ("session:fix-cache=ready_to_merge", .readyToMerge),
      ("session:fix-cache=done", .done),
    ])
    func aSessionWithAStateWaitsForThatState(_ text: String, _ state: AttentionState) throws {
      let wait = try condition(text)

      #expect(wait.kind == .session)
      #expect(wait.session?.name == "fix-cache")
      #expect(wait.state == state)
    }

    @Test func aBareNumberIsRefusedWithBothReadings() {
      do {
        _ = try condition("30")
        Issue.record("30 was accepted")
      } catch {
        #expect("\(error)".contains("#30"), "\(error)")
        #expect("\(error)".contains("30m"), "\(error)")
      }
    }

    @Test(arguments: [
      "soon", "", "  ", "session:", "session:=done", "session:x=bogus", "pr:abc", "pr:",
      "#", "#abc", "#0", "owner/name#abc", "https://example.com/owner/name/pull/123", "2026-11-14 09:00",
      "2026-11-14 12:00", "2026-11-13T09:00:00Z", "ci:123", "manual",
    ])
    func refusesWhatItCantUse(_ text: String) {
      #expect(throws: (any Error).self, "\(text) was accepted") { try condition(text) }
    }

    /// `makeWait` refuses a session that waits on itself, so the pause can't wait for the session that it pauses.
    @Test func aSessionConditionOnTheSessionItselfIsRefused() {
      #expect(throws: (any Error).self) { try condition("session:s1", waiter: "s1") }
    }

    @Test(arguments: [
      ("#123", "#123 merges"), ("owner/name#123", "owner/name#123 merges"),
      ("session:fix-cache", "fix-cache reaches Done"), ("session:fix-cache=needs_you", "fix-cache reaches Needs you"),
      ("2026-11-15 09:00", "at 2026-11-15 09:00"),
    ])
    func theLineSaysWhenTheParsedConditionResumes(_ text: String, _ phrase: String) throws {
      let pause = pauseOf(until: try condition(text))

      #expect(pause.line == "Paused by you; resumes when \(phrase)")
    }
  }
}
