import Foundation
import Testing

@testable import SwitchboardCore

private let loginMessage = "Login reached its time limit · Please run /login"
private let failedFolder = "/accounts/.claude-orchid"
private let otherFolder = "/accounts/.claude-personal"
private let readTheReply = "read its last reply and decide what's next"
private let acknowledgedMs = RecheckSettings().acknowledgedMs

/// The StopFailure event that sbd records for claude's hook. sbd stamps the session's account folder on it,
/// because the facts see only the event, and replay must rebuild the account that failed.
private func stopFailure(
  _ t: Int64, error: String = "authentication_failed", message: String? = loginMessage,
  account: String? = failedFolder, agent: String? = nil
) -> Event {
  var fields: [String: JSON] = ["error": .string(error)]
  if let message { fields["last_assistant_message"] = .string(message) }
  if let account { fields["account"] = .string(account) }
  if let agent { fields["agent_id"] = .string(agent) }
  return event("StopFailure", t, fields)
}

/// A first turn that ended with a plain reply, then a second turn that failed with `failure`.
private func failedTurn(_ failure: Event) -> [Event] {
  [
    event("SessionStart", 0), event("UserPromptSubmit", 1, ["prompt": "go"]),
    event("Stop", 2, ["last_assistant_message": "Done: go"]),
    event("UserPromptSubmit", 3, ["prompt": "next"]), failure,
  ]
}

private func onAccount(_ folder: String) -> Session {
  var s = session()
  s.claudeConfigDir = folder
  return s
}

private func ackEvent(_ t: Int64, _ verdict: Verdict, _ facts: SessionFacts) throws -> Event {
  let data = try JSON(encoding: Acknowledgment(verdict, facts))
  return event("ack", t, data.object ?? [:])
}

private func shown(_ s: Session, _ f: SessionFacts, at t: Int64) -> Verdict {
  Attention.shown(Attention.evaluate(s, f, now: t), f, now: t, acknowledgedMs: acknowledgedMs)
}

/// The suites nest under one name, so `--filter LoginFailureTests` runs them all.
@Suite struct LoginFailureTests {}

extension LoginFailureTests {
  @Suite struct Recording {
    @Test func aMainStopFailureRecordsTheErrorKind() throws {
      let f = facts(failedTurn(stopFailure(4)))

      #expect(try #require(f.turnFailure).error == "authentication_failed")
    }

    @Test func aMainStopFailureRecordsTheFailureMessage() throws {
      let f = facts(failedTurn(stopFailure(4)))

      #expect(try #require(f.turnFailure).message == loginMessage)
    }

    @Test func aMainStopFailureRecordsTheAccountThatFailed() throws {
      let f = facts(failedTurn(stopFailure(4)))

      #expect(try #require(f.turnFailure).account == failedFolder)
    }

    @Test func aMainStopFailureRecordsItsTime() throws {
      let f = facts(failedTurn(stopFailure(4)))

      #expect(try #require(f.turnFailure).at == 4)
    }

    @Test func aRateLimitStopFailureRecordsItsKind() throws {
      let f = facts(failedTurn(stopFailure(4, error: "rate_limit", message: nil)))

      #expect(try #require(f.turnFailure).error == "rate_limit")
    }

    @Test func aSubagentStopFailureRecordsNothing() {
      let f = facts(failedTurn(stopFailure(4, agent: "a1")))

      #expect(f.turnFailure == nil)
    }

    @Test func aSubagentStopFailureLeavesTheMainFailureAsItWas() throws {
      let f = facts(failedTurn(stopFailure(4)) + [stopFailure(5, error: "rate_limit", agent: "a1")])

      #expect(try #require(f.turnFailure).at == 4)
    }

    @Test func aMainUserPromptSubmitClearsTheFailure() {
      let f = facts(failedTurn(stopFailure(4)) + [event("UserPromptSubmit", 5, ["prompt": "try again"])])

      #expect(f.turnFailure == nil)
    }

    @Test func aMainStopClearsTheFailure() {
      let f = facts(failedTurn(stopFailure(4)) + [event("Stop", 5, ["last_assistant_message": "Back at it."])])

      #expect(f.turnFailure == nil)
    }

    @Test func aSubagentStopLeavesTheFailure() {
      let f = facts(
        failedTurn(stopFailure(4)) + [event("Stop", 5, ["last_assistant_message": "sub done", "agent_id": "a1"])])

      #expect(f.turnFailure != nil)
    }

    /// The resume trigger reads the failure after sbd stops the idle claude, moves the session, and starts claude
    /// again without a prompt. None of those events may clear it.
    @Test func theFailureSurvivesAStopAMoveAndAResumeWithoutAPrompt() {
      let f = facts(
        failedTurn(stopFailure(4)) + [
          event("stopped", 10),
          event("account-moved", 11, ["from": .string(failedFolder), "to": .string(otherFolder)]),
          event("resumed", 12), event("SessionStart", 13),
        ])

      #expect(f.turnFailure?.account == failedFolder)
    }

    @Test(arguments: [
      event("idle", 5), event("Notification", 5, ["notification_type": "idle_prompt"]),
      event("SessionEnd", 5, ["reason": "other"]), event("exited", 5),
    ])
    func anEndWithoutAStopLeavesTheFailure(_ end: Event) {
      let f = facts(failedTurn(stopFailure(4)) + [end])

      #expect(f.turnFailure != nil)
    }
  }
}

extension LoginFailureTests {
  @Suite struct Verdicts {
    /// A finished PR with a clean worktree reads Done, which would hide a later turn that the login stopped.
    @Test func aFinishedPRDoesNotHideAnExpiredLogin() throws {
      let f = try prFacts(
        samplePR(state: .merged), dirty: 0,
        then: [event("UserPromptSubmit", 10, ["prompt": "next"]), stopFailure(11)])

      let verdict = Attention.evaluate(onAccount(failedFolder), f, now: 12)

      #expect(verdict.state == .needsYou)
      #expect(verdict.loginFailed)
    }

    @Test func anExpiredLoginNeedsYou() {
      let f = facts(failedTurn(stopFailure(4)))

      #expect(Attention.evaluate(onAccount(failedFolder), f, now: 5).state == .needsYou)
    }

    @Test func theReasonSaysTheLoginExpiredAndToRunLogin() {
      let f = facts(failedTurn(stopFailure(4)))

      let reason = Attention.evaluate(onAccount(failedFolder), f, now: 5).reason

      #expect(reason.contains("login"))
      #expect(reason.contains("expired"))
      #expect(reason.contains("/login"))
    }

    /// The reason names the account that failed, which may differ from the session's account after a move.
    @Test func theReasonNamesTheAccountThatFailed() {
      let f = facts(failedTurn(stopFailure(4)))

      let reason = Attention.evaluate(onAccount(otherFolder), f, now: 5).reason

      #expect(reason.contains(ClaudeAccount(folder: failedFolder).name))
    }

    @Test(arguments: [
      "~/.claude-orchid", "~/.claude-orchid/", "\(NSHomeDirectory())/.claude-orchid",
      "\(NSHomeDirectory())/.claude-orchid/",
    ])
    func theReasonNamesTheAccountHoweverItsFolderIsWritten(_ folder: String) {
      let f = facts(failedTurn(stopFailure(4, account: folder)))

      let reason = Attention.evaluate(onAccount(folder), f, now: 5).reason

      #expect(reason.contains("orchid"))
      #expect(!reason.contains(folder))
    }

    @Test func theReasonIsNotTheGenericReplyLine() {
      let f = facts(failedTurn(stopFailure(4)))

      #expect(Attention.evaluate(onAccount(failedFolder), f, now: 5).reason != readTheReply)
    }

    /// A rule verdict, not the stale reply, decides the item. The Inbox would otherwise summarize the older reply.
    @Test func theVerdictDoesNotComeFromTheStaleReply() {
      let f = facts(failedTurn(stopFailure(4)))

      #expect(Attention.evaluate(onAccount(failedFolder), f, now: 5).source != .reply)
    }

    @Test func anExpiredLoginWithoutAMessageStillNeedsYouWithTheLoginReason() {
      let f = facts(failedTurn(stopFailure(4, message: nil)))

      let v = Attention.evaluate(onAccount(failedFolder), f, now: 5)

      #expect(v.state == .needsYou)
      #expect(v.reason.contains("expired"))
    }

    @Test func aNewPromptAfterTheFailureReadsWorking() {
      let f = facts(failedTurn(stopFailure(4)) + [event("UserPromptSubmit", 5, ["prompt": "go on"])])

      #expect(Attention.evaluate(onAccount(failedFolder), f, now: 6).state == .working)
    }

    @Test func aStopAfterTheFailureDropsTheLoginReason() {
      let f = facts(
        failedTurn(stopFailure(4)) + [
          event("UserPromptSubmit", 5, ["prompt": "go on"]), event("Stop", 6, ["last_assistant_message": "Done."]),
        ])

      #expect(Attention.evaluate(onAccount(failedFolder), f, now: 7) == Verdict(state: .needsYou, reason: readTheReply))
    }

    @Test func aRateLimitFailureDoesNotGetTheLoginReason() {
      let f = facts(failedTurn(stopFailure(4, error: "rate_limit", message: nil)))

      let reason = Attention.evaluate(onAccount(failedFolder), f, now: 5).reason

      #expect(!reason.contains("login"))
    }

    @Test func aRateLimitFailureKeepsTheVerdictOfTheReplyBeforeIt() {
      let before = facts(Array(failedTurn(stopFailure(4)).prefix(3)))
      let after = facts(failedTurn(stopFailure(4, error: "rate_limit", message: "API Error: 429")))

      #expect(
        Attention.evaluate(onAccount(failedFolder), after, now: 5)
          == Attention.evaluate(onAccount(failedFolder), before, now: 5))
    }

    @Test func aSubagentLoginFailureDoesNotGetTheLoginReason() {
      let f = facts(failedTurn(stopFailure(4, agent: "a1")))

      #expect(!Attention.evaluate(onAccount(failedFolder), f, now: 5).reason.contains("expired"))
    }
  }
}

extension LoginFailureTests {
  @Suite struct Acknowledging {
    @Test func anAckDoesNotDropAnExpiredLoginOutOfNeedsYou() throws {
      let s = onAccount(failedFolder)
      var f = facts(failedTurn(stopFailure(4)))
      let v = Attention.evaluate(s, f, now: 5)
      try #require(v.state == .needsYou)

      f.apply(try ackEvent(6, v, f))

      #expect(shown(s, f, at: 7).state == .needsYou)
    }

    @Test func anAckOfTheLoginReasonStillShowsTheLoginReason() throws {
      let s = onAccount(failedFolder)
      var f = facts(failedTurn(stopFailure(4)))
      let v = Attention.evaluate(s, f, now: 5)

      f.apply(try ackEvent(6, v, f))

      #expect(shown(s, f, at: 7).reason.contains("expired"))
    }

    /// The pair of the test above: once a Stop clears the failure, an ack sets the item aside as before.
    @Test func anAckMovesTheReplyVerdictToWaitingOnceTheFailureClears() throws {
      let s = onAccount(failedFolder)
      var f = facts(
        failedTurn(stopFailure(4)) + [
          event("UserPromptSubmit", 5, ["prompt": "go on"]), event("Stop", 6, ["last_assistant_message": "Done."]),
        ])
      let v = Attention.evaluate(s, f, now: 7)
      try #require(v.state == .needsYou)

      f.apply(try ackEvent(8, v, f))

      #expect(shown(s, f, at: 9).state == .waiting)
    }

    @Test func anAckMovesARateLimitFailureToWaitingAsBefore() throws {
      let s = onAccount(failedFolder)
      var f = facts(failedTurn(stopFailure(4, error: "rate_limit", message: nil)))
      let v = Attention.evaluate(s, f, now: 5)
      try #require(v.state == .needsYou)

      f.apply(try ackEvent(6, v, f))

      #expect(shown(s, f, at: 7).state == .waiting)
    }
  }
}

extension LoginFailureTests {
  /// `LoginResume.blocker` decides on each tick whether sbd continues a session whose turn failed on an expired
  /// login. Nil means the tick continues it.
  @Suite struct Resume {
    /// A live, idle session whose turn failed on `failedFolder` and that now runs under `account`.
    private func input(
      _ f: SessionFacts = facts(failedTurn(stopFailure(4))), account: String = otherFolder, loginWorks: Bool = false
    ) -> LoginResumeInput {
      var input = LoginResumeInput(session: onAccount(account), facts: f, now: 100)
      input.live = 1
      input.account = account
      input.loginWorks = loginWorks
      return input
    }

    @Test func aSessionMovedToAnotherAccountIsContinued() {
      #expect(LoginResume.blocker(input()) == nil)
    }

    @Test func aSessionOnTheFailedAccountWhoseLoginStillFailsIsHeldBack() {
      #expect(LoginResume.blocker(input(account: failedFolder)) != nil)
    }

    @Test func aSessionOnTheFailedAccountWhoseLoginWorksAgainIsContinued() {
      #expect(LoginResume.blocker(input(account: failedFolder, loginWorks: true)) == nil)
    }

    /// The failure keeps the folder as sbd stamped it, and the tick reads the session's account again. A guard that
    /// compares the two strings as written would take the same account, written another way, for a move.
    @Test(arguments: [
      ("~/.claude-orchid", "\(NSHomeDirectory())/.claude-orchid"),
      ("~/.claude-orchid/", "~/.claude-orchid"),
      ("\(NSHomeDirectory())/.claude-orchid/", "~/.claude-orchid"),
      ("\(NSHomeDirectory())/.claude-orchid", "\(NSHomeDirectory())/.claude-orchid/"),
    ])
    func theSameAccountWrittenAnotherWayIsNotAMove(_ stamped: String, _ current: String) {
      let f = facts(failedTurn(stopFailure(4, account: stamped)))

      #expect(LoginResume.blocker(input(f, account: current)) != nil)
    }

    @Test func aSessionWithNoFailureIsHeldBack() {
      let f = facts(Array(failedTurn(stopFailure(4)).prefix(3)))

      #expect(LoginResume.blocker(input(f, loginWorks: true)) != nil)
    }

    @Test func aRateLimitFailureIsHeldBackAfterAMove() {
      let f = facts(failedTurn(stopFailure(4, error: "rate_limit", message: nil)))

      #expect(LoginResume.blocker(input(f, loginWorks: true)) != nil)
    }

    @Test func aSubagentLoginFailureIsHeldBack() {
      let f = facts(failedTurn(stopFailure(4, agent: "a1")))

      #expect(LoginResume.blocker(input(f, loginWorks: true)) != nil)
    }

    /// An event that an older sbd recorded names no account, so neither trigger can show that the login works.
    @Test func aFailureThatNamesNoAccountIsHeldBack() {
      let f = facts(failedTurn(stopFailure(4, account: nil)))

      #expect(LoginResume.blocker(input(f, loginWorks: true)) != nil)
    }

    @Test func aHostSessionsFailureIsHeldBack() {
      let f = facts(failedTurn(stopFailure(4, account: Account.key(ofHost: "mini"))))

      #expect(LoginResume.blocker(input(f, loginWorks: true)) != nil)
    }

    @Test func aFailureThatAPromptClearedIsHeldBack() {
      let f = facts(failedTurn(stopFailure(4)) + [event("UserPromptSubmit", 5, ["prompt": "go on"])])

      #expect(LoginResume.blocker(input(f, loginWorks: true)) != nil)
    }

    /// Ticks run between the continue and the UserPromptSubmit that clears the failure. One failure gets one
    /// continue.
    @Test func aFailureThatSbdAlreadyContinuedIsHeldBack() {
      let f = facts(
        failedTurn(stopFailure(4)) + [
          event(LoginResume.eventKind, 10, ["text": .string(LoginResume.message), "delivery": "pasted"])
        ])

      #expect(LoginResume.blocker(input(f, loginWorks: true)) != nil)
    }

    /// A send that threw delivered nothing, so the next tick tries again.
    @Test func aContinueWhoseSendFailedIsTriedAgain() {
      let f = facts(
        failedTurn(stopFailure(4)) + [
          event(LoginResume.eventKind, 10, ["text": .string(LoginResume.message), "error": "claude is gone"])
        ])

      #expect(LoginResume.blocker(input(f, loginWorks: true)) == nil)
    }

    @Test func aNewFailureAfterAContinueIsContinuedAgain() {
      let f = facts(
        failedTurn(stopFailure(4)) + [
          event(LoginResume.eventKind, 10, ["text": .string(LoginResume.message), "delivery": "pasted"]),
          event("UserPromptSubmit", 11, ["prompt": .string(LoginResume.message)]),
          stopFailure(12, account: otherFolder),
        ])

      #expect(LoginResume.blocker(input(f, account: failedFolder)) == nil)
    }

    @Test func aSessionMarkedDoneIsHeldBack() {
      var i = input()
      i.session.done = true

      #expect(LoginResume.blocker(i) != nil)
    }

    @Test func aSessionWithAMessageOnItsWayIsHeldBack() {
      var i = input()
      i.busy = true

      #expect(LoginResume.blocker(i) != nil)
    }

    @Test func aStoppedClaudeWithTheLiveCapFullIsHeldBack() {
      var i = input()
      i.process = .stopped
      i.live = 12
      i.liveCap = 12

      #expect(LoginResume.blocker(i) == "the live cap of 12 is full")
    }

    /// A login that still fails after a continue fails the next turn too. The hourly cap ends that loop.
    @Test func continuesPastTheHourlyCapAreHeldBack() {
      var events = failedTurn(stopFailure(4))
      for n in 0..<Int64(LoginResume.perHour) {
        let t = 10 + n * 3
        events += [
          event(LoginResume.eventKind, t, ["text": .string(LoginResume.message), "delivery": "pasted"]),
          event("UserPromptSubmit", t + 1, ["prompt": .string(LoginResume.message)]),
          stopFailure(t + 2, account: failedFolder),
        ]
      }
      var i = input(facts(events), account: failedFolder, loginWorks: true)
      i.now = 100

      #expect(LoginResume.blocker(i)?.contains("in the last hour") == true)
    }

    @Test func aHostKeyNamesTheHost() {
      #expect(TurnFailure.accountName("mini:~/.claude") == "mini")
      #expect(TurnFailure.sameAccount("mini:~/.claude", "mini:~/.claude"))
      #expect(!TurnFailure.sameAccount("mini:~/.claude", "studio:~/.claude"))
    }

    @Test func theMessageSaysThePreviousTurnFailedOnAnExpiredLogin() {
      #expect(LoginResume.message.lowercased().contains("login"))
    }

    @Test func theMessageAsksClaudeToContinueWhereItLeftOff() {
      #expect(LoginResume.message.lowercased().contains("continue where you left off"))
    }
  }
}
