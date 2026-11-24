import Foundation
import Testing

@testable import SwitchboardCore

func session(done: Bool = false, wait: String? = nil) -> Session {
  var s = Session(id: "s1", name: "test", cwd: "/tmp", claudeSessionId: "uuid", created: 0)
  s.done = done
  if let wait { s.waits = [Wait(id: "w1", kind: .manual, note: wait, created: 0, then: .notify)] }
  return s
}

func event(_ kind: String, _ t: Int64, _ fields: [String: JSON] = [:]) -> Event {
  Event(session: "s1", t: t, kind: kind, data: .object(fields))
}

/// The prompt that UserPromptSubmit carried for a message from another
/// session on Claude Code 2.1.319.
let peerMessage =
  "<cross-session-message from=\"uds:/tmp/cc-socks/86186.sock\" from-name=\"rebase-7\" from-mode=\"prompting\">\n"
  + "Rebase please.\n</cross-session-message>"

func facts(_ events: [Event]) -> SessionFacts {
  var f = SessionFacts()
  for e in events { f.apply(e) }
  return f
}

func tool(_ name: String, _ input: [String: JSON], id: String? = nil, agent: String? = nil) -> [String: JSON] {
  var fields: [String: JSON] = ["tool_name": .string(name), "tool_input": .object(input)]
  if let id { fields["tool_use_id"] = .string(id) }
  if let agent { fields["agent_id"] = .string(agent) }
  return fields
}

@Suite struct AttentionRules {
  @Test func newSessionNeedsAFirstPrompt() {
    let v = Attention.evaluate(session(), facts([event("SessionStart", 1)]), now: 2)
    #expect(v == Verdict(state: .needsYou, reason: "give it a first prompt"))
  }

  @Test(arguments: ["started", "resumed"]) func aLaunchPromptThatClaudeHasNotTakenReadsWorking(_ kind: String) {
    let f = facts([event(kind, 1, ["prompt": "fix it"])])
    let v = Attention.evaluate(session(), f, now: 2)
    #expect(v == Verdict(state: .working, reason: "starting with its first prompt"))
    let started = facts([event(kind, 1, ["prompt": "fix it"]), event("SessionStart", 5)])
    #expect(Attention.evaluate(session(), started, now: 6).state == .working)
  }

  @Test func aLaunchWithoutAPromptStillNeedsAFirstPrompt() {
    for prompt in [nil, ""] as [String?] {
      let f = facts([event("started", 1, prompt.map { ["prompt": .string($0)] } ?? [:]), event("SessionStart", 2)])
      #expect(Attention.evaluate(session(), f, now: 3) == Verdict(state: .needsYou, reason: "give it a first prompt"))
    }
  }

  @Test(arguments: ["exited", "stopped", "SessionEnd"]) func aClaudeThatEndsBeforeTakingTheLaunchPromptNeedsYou(
    _ ending: String
  ) {
    let f = facts([event("started", 1, ["prompt": "fix it"]), event(ending, 4)])
    #expect(Attention.evaluate(session(), f, now: 5) == Verdict(state: .needsYou, reason: "give it a first prompt"))
  }

  @Test func aRelaunchWithAPromptAfterAnExitReadsWorkingAgain() {
    let f = facts([
      event("started", 1, ["prompt": "a"]), event("exited", 4), event("resumed", 10, ["prompt": "b"]),
    ])
    #expect(Attention.evaluate(session(), f, now: 11).state == .working)
  }

  @Test func aLaunchPromptThatNeverArrivesStopsHidingTheSession() {
    let f = facts([event("started", 1, ["prompt": "fix it"])])
    let late = 1 + SessionFacts.launchPromptWindowMs
    #expect(Attention.evaluate(session(), f, now: late - 1).state == .working)
    #expect(Attention.evaluate(session(), f, now: late) == Verdict(state: .needsYou, reason: "give it a first prompt"))
  }

  @Test func theLaunchPromptIsTakenWhenClaudeSubmitsIt() {
    let f = facts([
      event("started", 1, ["prompt": "fix it"]), event("SessionStart", 2),
      event("UserPromptSubmit", 3, ["prompt": "fix it"]),
      event("Stop", 4, ["last_assistant_message": "Done."]),
    ])
    #expect(!f.launchPromptPending(now: 5))
    #expect(Attention.evaluate(session(), f, now: 5).state != .working)
  }

  @Test func aFirstMessagePastedIntoABareSessionReadsWorking() {
    let f = facts([event("started", 1), event("SessionStart", 2), event("pasting", 3, ["text": "fix it"])])
    #expect(
      Attention.evaluate(session(), f, now: 4) == Verdict(state: .working, reason: "starting with its first prompt"))
  }

  @Test(arguments: ["started", "resumed"]) func aBuiltInCommandAsTheLaunchPromptLeavesNothingPending(_ kind: String) {
    let f = facts([event(kind, 1, ["prompt": "/compact"]), event("SessionStart", 2)])
    #expect(!f.launchPromptPending(now: 3))
    #expect(Attention.evaluate(session(), f, now: 3) == Verdict(state: .needsYou, reason: "give it a first prompt"))
  }

  @Test func aTrustDialogExitComesBeforeAPendingLaunchPrompt() {
    var f = facts([event("started", 1, ["prompt": "fix it"])])
    f.exitedAtTrust = true
    #expect(Attention.evaluate(session(), f, now: 2).state == .needsYou)
  }

  @Test func runningTurnIsWorkingWithItsTool() {
    let f = facts([
      event("SessionStart", 0), event("UserPromptSubmit", 1000, ["prompt": "go"]),
      event("PreToolUse", 2000, tool("Bash", ["command": "make test"], id: "t1")),
    ])
    let v = Attention.evaluate(session(), f, now: 2000 + 3 * 60_000)
    #expect(v == Verdict(state: .working, reason: "`make test` (3 min)"))
  }

  @Test func toolThatFinishedLeavesTheTurnWorking() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("PreToolUse", 1, tool("Read", ["file_path": "/a/b.swift"], id: "r1")),
      event("PostToolUse", 2, tool("Read", ["file_path": "/a/b.swift"], id: "r1")),
    ])
    #expect(Attention.evaluate(session(), f, now: 3).state == .working)
    #expect(f.runningTool == nil)
  }

  @Test func anotherCallOfTheSameToolLeavesTheRunningOne() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("PreToolUse", 1, tool("Bash", ["command": "make"], id: "a")),
      event("PostToolUse", 2, tool("Bash", ["command": "ls"], id: "b")),
    ])
    #expect(f.runningTool?.id == "a")
  }

  @Test func permissionRequestNeedsYouUntilItsToolRuns() {
    let rm = tool("Bash", ["command": "rm -rf build"], id: "x")
    var events = [
      event("UserPromptSubmit", 0, ["prompt": "go"]), event("PreToolUse", 1, rm),
      event("PermissionRequest", 2, tool("Bash", ["command": "rm -rf build"])),
    ]
    #expect(
      Attention.evaluate(session(), facts(events), now: 3)
        == Verdict(state: .needsYou, reason: "approve `rm -rf build`"))
    // Another tool that finishes leaves the prompt open.
    events.append(event("PostToolUse", 4, tool("Read", ["file_path": "/a"], id: "y")))
    #expect(Attention.evaluate(session(), facts(events), now: 5).state == .needsYou)
    events.append(event("PostToolUse", 6, rm))
    #expect(Attention.evaluate(session(), facts(events), now: 7).state == .working)
  }

  @Test func notificationOnlyPermissionPromptClearsWhenAToolFinishes() {
    let events = [
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("Notification", 1, ["notification_type": "permission_prompt", "message": "Allow Bash?"]),
    ]
    #expect(Attention.evaluate(session(), facts(events), now: 2).state == .needsYou)
    let done = events + [event("PostToolUse", 3, tool("Bash", ["command": "ls"], id: "b"))]
    #expect(facts(done).openPermission == nil)
    #expect(Attention.evaluate(session(), facts(done), now: 4).state == .working)
  }

  @Test func askUserQuestionNeedsAnAnswer() {
    let input: [String: JSON] = ["questions": [["question": "Which fruit?"]]]
    var events = [
      event("UserPromptSubmit", 0, ["prompt": "go"]), event("PreToolUse", 1, tool("AskUserQuestion", input, id: "q")),
    ]
    // The PermissionRequest for the same question doesn't turn it into a permission prompt.
    events.append(event("PermissionRequest", 2, tool("AskUserQuestion", input)))
    let f = facts(events)
    #expect(f.openPermission == nil)
    #expect(Attention.evaluate(session(), f, now: 3) == Verdict(state: .needsYou, reason: "answer: Which fruit?"))
    #expect(
      Attention.evaluate(
        session(), facts(events + [event("PostToolUse", 4, tool("AskUserQuestion", input, id: "q"))]), now: 5
      ).state == .working)
  }

  @Test func subagentToolCallsDontChangeTheMainSession() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "Want me to push?"]),
      event("SubagentStart", 2, ["agent_id": "a1"]),
      event("PreToolUse", 3, tool("Bash", ["command": "ls"], agent: "a1")),
      event("PermissionRequest", 4, tool("Bash", ["command": "ls"], agent: "a1")),
    ])
    #expect(f.runningTool == nil)
    #expect(f.openPermission == nil)
    #expect(!f.turnRunning)
    #expect(f.subagents == ["a1"])
    #expect(Attention.evaluate(session(), f, now: 5).state == .canContinue)
  }

  @Test func turnEndedWithASubagentRunningIsWaiting() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("SubagentStart", 1, ["agent_id": "a1"]),
      event("Stop", 2, ["last_assistant_message": "I'll wait for the review."]),
    ])
    #expect(Attention.evaluate(session(), f, now: 3) == Verdict(state: .waiting, reason: "waiting on 1 subagent"))
  }

  @Test func turnEndedWithSeveralReviewersRunningIsWaiting() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "/review-code"]),
      event("SubagentStart", 1, ["agent_id": "a1", "agent_type": "code-reviewer-correctness"]),
      event("SubagentStart", 2, ["agent_id": "a2", "agent_type": "code-reviewer-testing"]),
      event(
        "Stop", 3,
        ["last_assistant_message": "Two reviewers are still running. I'll validate the findings once they report."]),
    ])
    #expect(Attention.evaluate(session(), f, now: 4) == Verdict(state: .waiting, reason: "waiting on 2 subagents"))
  }

  @Test func turnEndedWithABackgroundJobRunningIsWaiting() {
    let ended = [
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("Stop", 2, ["last_assistant_message": "I'll wait for the task notification."]),
    ]
    let one = facts(ended + [event("job", 3, ["count": 1])])
    #expect(
      Attention.evaluate(session(), one, now: 4) == Verdict(state: .waiting, reason: "waiting on 1 background job"))
    let two = facts(ended + [event("job", 3, ["count": 2])])
    #expect(Attention.evaluate(session(), two, now: 4).reason == "waiting on 2 background jobs")
    let gone = facts(ended + [event("job", 3, ["count": 1]), event("job", 4, ["count": 0])])
    #expect(Attention.evaluate(session(), gone, now: 4 + Attention.jobReportMs).state == .needsYou)
  }

  @Test func reportOfABackgroundJobReturnsTheSessionToTheUser() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("Stop", 1, ["last_assistant_message": "I'll wait for the task notification."]),
      event("job", 2, ["count": 1]),
      event("job", 3, ["count": 0]),
      event("UserPromptSubmit", 4, ["prompt": "<task-notification>done</task-notification>"]),
      event("Stop", 5, ["last_assistant_message": "The review found nothing."]),
    ])
    #expect(Attention.evaluate(session(), f, now: 6).state == .needsYou)
  }

  @Test func questionStillNeedsYouWhileAJobRuns() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("Stop", 1, ["last_assistant_message": "The server is up. Which page should I test first?"]),
      event("job", 2, ["count": 1]),
    ])
    #expect(Attention.evaluate(session(), f, now: 3).state == .needsYou)
  }

  @Test func offerWaitsWhileAJobRuns() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("Stop", 1, ["last_assistant_message": "The server is up. Want me to run the tests?"]),
      event("job", 2, ["count": 1]),
    ])
    #expect(Attention.evaluate(session(), f, now: 3).state == .waiting)
  }

  @Test func subagentsOutrankBackgroundJobs() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), event("SubagentStart", 1, ["agent_id": "a1"]),
      event("Stop", 2, ["last_assistant_message": "Waiting for the review."]), event("job", 3, ["count": 1]),
    ])
    #expect(Attention.evaluate(session(), f, now: 4) == Verdict(state: .waiting, reason: "waiting on 1 subagent"))
  }

  @Test func idleSessionWithAJobIsStaleAfterTwoDays() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "Server started."]),
      event("job", 2, ["count": 1]),
    ])
    #expect(Attention.evaluate(session(), f, now: 2 + Attention.staleAfterMs + 1).state == .stale)
  }

  @Test func exitedClaudeHasNoBackgroundJobs() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "Done."]),
      event("job", 2, ["count": 1]), event("exited", 3),
    ])
    #expect(f.jobs == 0)
  }

  @Test func jobEventsDontCountAsActivity() {
    let f = facts([event("Stop", 1), event("job", 500, ["count": 1])])
    #expect(f.lastActivity == 1)
  }

  @Test func subagentStopReturnsTheSessionToTheReplyVerdict() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("SubagentStart", 1, ["agent_id": "a1"]),
      event("Stop", 2, ["last_assistant_message": "I'll wait for the review."]),
      event("SubagentStop", 3, ["agent_id": "a1"]),
    ])
    #expect(Attention.evaluate(session(), f, now: 4).state == .needsYou)
  }

  @Test func subagentThatWentQuietNoLongerHoldsTheSession() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("SubagentStart", 1, ["agent_id": "a1"]),
      event("Stop", 2, ["last_assistant_message": "I'll wait for the review."]),
    ])
    #expect(Attention.evaluate(session(), f, now: 2 + Attention.subagentQuietMs + 1).state == .needsYou)
  }

  @Test func subagentResultAndPeerPromptsDontCountAsPrompts() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "<agent-message from=\"a1\"> [Subagent hand-back] done"]),
      event("UserPromptSubmit", 1, ["prompt": "<task-notification><task-id>a1</task-id></task-notification>"]),
      event("UserPromptSubmit", 2, ["prompt": .string(peerMessage)]),
    ])
    #expect(f.prompts == 0)
  }

  @Test func stopRecordsTheReplyAndEndsTheTurn() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("PreToolUse", 1, tool("Bash", ["command": "make"], id: "m")),
      event("Stop", 2, ["last_assistant_message": "Which schema do you want, A or B?"]),
    ])
    #expect(!f.turnRunning)
    #expect(f.runningTool == nil)
    #expect(
      Attention.evaluate(session(), f, now: 3)
        == Verdict(state: .needsYou, reason: "answer: Which schema do you want, A or B?"))
  }

  @Test(arguments: [
    event("StopFailure", 3, ["error": "rate_limit"]),
    event("Notification", 3, ["notification_type": "idle_prompt"]),
    event("idle", 3),
  ])
  func aTurnEndsWithoutAStop(_ end: Event) {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("PreToolUse", 1, tool("Bash", ["command": "make"], id: "m")),
      event("PermissionRequest", 2, tool("Bash", ["command": "make"])), end,
    ])
    #expect(!f.turnRunning)
    #expect(f.openPermission == nil)
    #expect(f.runningTool == nil)
  }

  @Test func aNewPromptClearsTheInterruptedTool() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("PreToolUse", 1, tool("Bash", ["command": "npm test"], id: "n")),
      event("UserPromptSubmit", 2, ["prompt": "do X instead"]),
    ])
    #expect(f.runningTool == nil)
    #expect(f.turnStarted == 0)
  }

  @Test func sessionEndClearsOpenPrompts() {
    let f = facts([
      event("SessionStart", 0), event("UserPromptSubmit", 1, ["prompt": "go"]),
      event("PermissionRequest", 2, tool("Bash", ["command": "x"])), event("SessionEnd", 3, ["reason": "other"]),
    ])
    #expect(!f.live)
    #expect(f.openPermission == nil)
    #expect(!f.turnRunning)
  }

  @Test func doneWinsOverEverything() {
    let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"])])
    #expect(Attention.evaluate(session(done: true), f, now: 1) == Verdict(state: .done, reason: "marked done"))
  }

  @Test func waitNoteIsWaitingWhenIdle() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "Pushed."]),
    ])
    #expect(Attention.evaluate(session(wait: "CI on #12"), f, now: 2) == Verdict(state: .waiting, reason: "CI on #12"))
  }

  @Test func idleForTwoDaysIsStale() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "Pushed."]),
    ])
    #expect(Attention.evaluate(session(), f, now: Attention.staleAfterMs + 10).state == .stale)
  }

  @Test func trackRecordsWhenTheStateChanged() {
    var f = facts([event("UserPromptSubmit", 0, ["prompt": "go"])])
    Attention.track(session(), &f, now: 100)
    Attention.track(session(), &f, now: 200)
    #expect(f.stateSince == 100)
    f.apply(event("Stop", 300, ["last_assistant_message": "Want me to push?"]))
    Attention.track(session(), &f, now: 300)
    #expect(f.stateSince == 300)
  }
}

@Suite struct ReplyClassifier {
  @Test(arguments: [
    ("Want me to run the tests?", ReplyKind.offer("Want me to run the tests?")),
    ("I fixed it.\n\nShould I push the branch?", .offer("Should I push the branch?")),
    ("Which schema should I use, A or B?", .question("Which schema should I use, A or B?")),
    ("Do you want the CSV or the JSON export?", .question("Do you want the CSV or the JSON export?")),
    ("Done. Tests pass.\n\nNext, I'll update the docs.", .offer("Next, I'll update the docs.")),
    ("All tests pass and the PR is up.", .other),
    ("", .other),
    ("Is this right? I think so.\n\nThe build passes.", .other),
    ("**Do you want me to open the PR?**", .offer("Do you want me to open the PR?")),
    ("Want me to update README.md?", .offer("Want me to update README.md?")),
    ("**Want me to push?** I can also open the PR.", .offer("Want me to push?")),
    ("Shall I tag it \"v2?\"", .offer("Shall I tag it \"v2?")),
    ("Shall I tag it \u{201C}v2?\u{201D}", .offer("Shall I tag it \u{201C}v2?")),
    ("Want me to push?!", .offer("Want me to push?")),
    (
      "I left the old flag in place (should I remove it?)",
      .question("I left the old flag in place (should I remove it?")
    ),
    ("Which of v1.2.3 or v1.3.0 should I ship?", .question("Which of v1.2.3 or v1.3.0 should I ship?")),
    ("Done.\n\nWant me to open https://example.com/a.b?", .offer("Want me to open https://example.com/a.b?")),
    ("Should it be renamed?", .question("Should it be renamed?")),
    ("Should I push?", .offer("Should I push?")),
    ("Okay to merge?", .offer("Okay to merge?")),
  ])
  func classifies(_ reply: String, _ kind: ReplyKind) {
    #expect(Attention.classify(reply) == kind)
  }
}

@Suite struct LastQuestion {
  @Test func givesTheLastParagraphsLastQuestionAndTheSentenceBeforeIt() throws {
    let reply = "Is this right? I think so.\n\nDone. Want me to push? I can also open the PR."

    let found = try #require(Attention.lastQuestion(reply))

    #expect(found.question == "Want me to push?")
    #expect(found.previous == "Done.")
  }

  @Test func picksTheLastOfSeveralQuestions() throws {
    let found = try #require(Attention.lastQuestion("I fixed it.\n\nShould I push the branch? Or wait?"))

    #expect(found.question == "Or wait?")
    #expect(found.previous == "Should I push the branch?")
  }

  @Test func aQuestionThatStartsItsParagraphHasNoPreviousSentence() throws {
    let found = try #require(Attention.lastQuestion("I made `haacked/x-v2`.\n\nDo you want me to delete it?"))

    #expect(found.question == "Do you want me to delete it?")
    #expect(found.previous == nil)
  }

  /// `OfferText` reads the previous sentence's code spans, so its backticks stay.
  @Test func thePreviousSentenceKeepsALeadingCodeSpan() throws {
    let found = try #require(Attention.lastQuestion("`haacked/x-v2` still exists on origin. Want me to delete it?"))

    #expect(found.previous?.hasPrefix("`haacked/x-v2`") == true)
  }

  @Test(arguments: ["All tests pass.", "", "Is this right?\n\nThe build passes.", "Next, I'll update the docs."])
  func isNilWhenTheLastParagraphAsksNoQuestion(_ reply: String) {
    #expect(Attention.lastQuestion(reply) == nil)
  }
}

@Suite struct OfferPrefix {
  @Test(arguments: [
    ("Do you want me to delete it?", "do you want me to"),
    ("Should I push?", "should i"),
    ("SHOULD I push?", "should i"),
    ("Should I\tpush?", "should i"),
    ("Ok to merge?", "ok to"),
    ("Okay to merge?", "okay to"),
    ("Want me to merge it?", "want me to"),
    ("Want to see it?", "want to"),
  ])
  func givesTheOfferStartThatWhitespaceFollows(_ sentence: String, _ prefix: String) {
    #expect(Attention.offerPrefix(sentence) == prefix)
  }

  /// A prefix counts only at a word boundary, so these are questions.
  @Test(arguments: [
    "Should it be renamed?", "Should Ingrid review it?", "Okay tomorrow?", "Want to?", "Shall weigh in?",
    "Wanting more?", "Which branch should I use?",
  ])
  func givesNothingWhenTheOfferStartRunsIntoAWord(_ sentence: String) {
    #expect(Attention.offerPrefix(sentence) == nil)
  }
}

@Suite struct Text {
  @Test func oneLineJoinsAndCuts() {
    #expect(oneLine("a\n\n  b  \nc") == "a b c")
    #expect(oneLine(String(repeating: "x", count: 80), max: 10) == "xxxxxxxxx…")
  }

  @Test func toolSummaries() {
    #expect(Attention.toolSummary("Edit", ["file_path": "/x/y/Main.swift"]) == "Edit Main.swift")
    #expect(Attention.toolSummary("mcp__grafana__list_datasources", nil) == "grafana list datasources")
  }

  @Test(arguments: [1e19, -1e19, .nan, .infinity, 1.5])
  func intIsNilForANumberThatIsNotAnInt(_ n: Double) {
    #expect(JSON.number(n).int == nil)
  }

  @Test func jsonRoundTrips() {
    let text = #"{"a":[1,true,null,"x"],"b":{"c":2.5}}"#
    #expect(JSON.parse(text)?.text == text)
  }
}

/// A turn that started a background job, and the job's exit at t = 10.
private let jobEndsAfterTheTurn = [
  event("UserPromptSubmit", 0, ["prompt": "go"]), event("job", 1, ["count": 1]), stop(3, 2, "Started a job."),
  event("job", 10, ["count": 0]),
]

@Suite struct JobReportWait {
  @Test func sessionWaitsForTheReportOfAJobThatEndedAfterItsTurn() {
    let f = facts(jobEndsAfterTheTurn)

    #expect(
      Attention.evaluate(session(), f, now: 10 + Attention.jobReportMs - 1)
        == Verdict(state: .waiting, reason: "waiting for claude to report its background job"))
    #expect(Attention.evaluate(session(), f, now: 10 + Attention.jobReportMs).state == .needsYou)
  }

  @Test(arguments: ["UserPromptSubmit", "Stop"])
  func aNewTurnEndsTheWait(_ kind: String) {
    let f = facts(jobEndsAfterTheTurn + [event(kind, 11, ["prompt": "<task-notification>"])])

    #expect(!f.mayReportJob(now: 12))
  }

  @Test func aTurnWithoutJobsWaitsForNoReport() {
    let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"]), stop(3, 2, "Done.")])

    #expect(!f.mayReportJob(now: 3))
  }
}

/// The reason that a session gives after claude exited at the trust dialog.
let exitedAtTrustReason = "claude exited at the folder trust prompt. Open the session to answer it again"

@Suite struct TrustAttention {
  /// `reason` abbreviates the folder with the home of the process that runs
  /// the test, so the folder is under that home.
  @Test func aTrustCardOutranksTheFirstPromptRule() throws {
    let f = facts(trustLaunch(folder: "\(NSHomeDirectory())/dev/repo"))
    try #require(f.prompts == 0 && f.lastReply == nil)

    let verdict = Attention.evaluate(session(), f, now: 4)

    #expect(verdict == Verdict(state: .needsYou, reason: "trust the folder ~/dev/repo"))
  }

  @Test func aTrustCardOutsideTheHomeNamesTheWholeFolder() {
    let f = facts(trustLaunch(folder: "/private/tmp/w"))

    #expect(Attention.evaluate(session(), f, now: 4).reason == "trust the folder /private/tmp/w")
  }

  /// Exit on the card records `answered` and then `trust_closed`. Exit
  /// typed in the terminal, `sb stop`, and a crash record only `trust_closed`.
  @Test(arguments: [false, true])
  func exitedAtTrustSaysSo(_ answeredFirst: Bool) throws {
    let answer = answeredFirst ? [event("answered", 5, ["card": 5, "behavior": "deny", "delivery": "terminal"])] : []
    let f = facts(trustLaunch() + answer + [trustClosed(5), event("exited", 7)])
    try #require(f.prompts == 0 && f.lastReply == nil)

    let verdict = Attention.evaluate(session(), f, now: 8)

    #expect(verdict == Verdict(state: .needsYou, reason: exitedAtTrustReason))
  }

  @Test func exitedAtTrustKeepsSayingSoAfterARestart() {
    var replay = SessionReplay.replaying(trustLaunch() + [trustClosed(5)], session: session())

    replay.restarted()

    #expect(Attention.evaluate(session(), replay.facts, now: 8).reason == exitedAtTrustReason)
  }

  @Test(arguments: ["started", "resumed"])
  func aNewLaunchClearsExitedAtTrust(_ kind: String) {
    let f = facts(trustLaunch() + [trustClosed(5), event(kind, 9, ["prompt": .null])])

    #expect(!f.exitedAtTrust)
    #expect(Attention.evaluate(session(), f, now: 10).reason != exitedAtTrustReason)
  }

  /// The next launch's own dialog asks again with a card, which outranks the exit.
  @Test func theNextLaunchsDialogShowsItsCard() {
    let f = facts(
      trustLaunch() + [trustClosed(5), event("resumed", 9, ["prompt": .null]), trustDialog(id: 11, t: 10, launch: 9)])

    #expect(f.cards.map(\.id) == [11])
    #expect(Attention.evaluate(session(), f, now: 11).reason == "trust the folder /w/repo")
  }

  @Test func trustLaunchAndLastLaunchPromptFollowTheLaunchEvents() {
    var f = SessionFacts()

    f.apply(event("started", 1, ["prompt": "hello"]))
    #expect(f.lastLaunchPrompt == "hello")
    #expect(f.trustLaunch == nil)

    f.apply(trustDialog(t: 3, launch: 1))
    #expect(f.trustLaunch == 1)
    #expect(f.trustLaunch == f.lastLaunch)

    f.apply(event("resumed", 7, ["prompt": .null]))
    #expect(f.lastLaunchPrompt == nil)
    #expect(f.lastLaunch == 7)
    #expect(f.trustLaunch != f.lastLaunch)

    f.apply(event("resumed", 9, ["prompt": "again"]))
    #expect(f.lastLaunchPrompt == "again")
  }

  @Test(arguments: ["hello", "null", "", "  42  ", "Say \"hi\"\nthen"])
  func lastLaunchPromptKeepsThePromptExactly(_ prompt: String) {
    #expect(facts([event("started", 1, ["prompt": .string(prompt)])]).lastLaunchPrompt == prompt)
  }

  @Test func aLaunchWithoutAPromptFieldHasNoPrompt() {
    #expect(facts([event("started", 1, ["prompt": "hello"]), event("resumed", 2)]).lastLaunchPrompt == nil)
  }

  @Test(arguments: [
    event("SessionStart", 3), event("UserPromptSubmit", 3, ["prompt": "go"]),
    event("Notification", 3, ["notification_type": "idle_prompt"]), event("Stop", 3), event("SessionEnd", 3),
    event("PreToolUse", 3, tool("Bash", ["command": "ls"], id: "b1")),
  ])
  func aHookSinceTheLaunchIsAHookSinceLaunch(_ hook: Event) {
    #expect(facts([event("started", 1, ["prompt": "hello"]), hook]).hookSinceLaunch)
  }

  /// sbd's own events and a subagent's hooks don't set `hookSinceLaunch`.
  @Test(arguments: [
    event("running", 3), event("job", 3, ["count": 1]), event("sent", 3, ["text": "hi", "delivery": "queued"]),
    trustDialog(t: 3), event("PreToolUse", 3, tool("Bash", ["command": "ls"], agent: "a1")),
  ])
  func otherEventsAreNoHookSinceLaunch(_ other: Event) {
    #expect(!facts([event("started", 1, ["prompt": "hello"]), other]).hookSinceLaunch)
  }

  @Test(arguments: ["started", "resumed"])
  func aNewLaunchClearsHookSinceLaunch(_ kind: String) {
    let f = facts([event("started", 1), event("SessionStart", 2), event(kind, 5, ["prompt": .null])])

    #expect(!f.hookSinceLaunch)
  }
}

/// Why an open prompt has no card, which the Inbox item says in its summary.
@Suite struct CardlessPrompt {
  static let notificationOnly =
    "Claude Code didn't send Switchboard this prompt's tool call, so Switchboard has no card for it. "
    + "Answer it in the terminal."
  static let unreadable =
    "Claude Code stopped waiting on Switchboard for this prompt. That happens when sbd restarts, when the request "
    + "times out, or when the prompt is answered in the terminal. Switchboard can't read this tool's dialog on the "
    + "screen. If the dialog still shows, answer it in the terminal."
  static let dialogLeft =
    "The dialog left the terminal without an answer from Switchboard, as No or Escape in the terminal does. "
    + "Open the Terminal to see where the session stands."
  static let dialogLeftAfterHookClosed =
    "The dialog left the terminal after Claude Code stopped waiting on Switchboard, so Switchboard can't tell "
    + "whether it was allowed. Open the Terminal to see where the session stands."
  static let noCard = "Switchboard has no card for this prompt. Answer it in the terminal."

  /// The facts after `events` and an sbd restart, then `after`.
  static func restarted(_ events: [Event], then after: [Event] = []) -> SessionFacts {
    var replay = SessionReplay.replaying(events, session: session())
    replay.restarted()
    for e in after { replay.apply(e, session: session()) }
    return replay.facts
  }

  /// A question whose PreToolUse opens it before any PermissionRequest
  /// gives it a card.
  static let questionWithoutACard = event("PreToolUse", 20, ask())

  static let permissionNotification = event(
    "Notification", 10, ["notification_type": "permission_prompt", "message": "Claude needs your permission"])

  /// A question with no text, so the card has no marks.
  static func unmarkedQuestionTurn() -> [Event] {
    let questions: JSON = ["questions": [["options": [["label": "a"]]]]]
    return promptTurn(ask(questions), ask(questions, id: nil))
  }

  enum Cause: CaseIterable {
    case fetchRestarted, fetchHookClosed, editDialogLeft, editRestartedThenDialogLeft, notificationOnly
    case unmarkedQuestionRestarted, notificationAfterTheFetchCardWent

    var sessionFacts: SessionFacts {
      switch self {
      case .fetchRestarted:
        return CardlessPrompt.restarted(fetchTurn())
      case .fetchHookClosed:
        return facts(fetchTurn() + [event("card_closed", 4, ["card": 3])])
      case .editDialogLeft:
        return facts(editTurn() + [event("dialog_closed", 4, ["card": 3])])
      case .editRestartedThenDialogLeft:
        return CardlessPrompt.restarted(editTurn(), then: [event("dialog_closed", 4, ["card": 3])])
      case .notificationOnly:
        return facts([
          event("UserPromptSubmit", 0, ["prompt": "go"]), CardlessPrompt.permissionNotification,
        ])
      case .unmarkedQuestionRestarted:
        return CardlessPrompt.restarted(CardlessPrompt.unmarkedQuestionTurn())
      case .notificationAfterTheFetchCardWent:
        return facts(
          fetchTurn() + [event("card_closed", 4, ["card": 3]), CardlessPrompt.permissionNotification])
      }
    }

    var reason: String {
      switch self {
      case .fetchRestarted, .fetchHookClosed, .unmarkedQuestionRestarted, .notificationAfterTheFetchCardWent:
        CardlessPrompt.unreadable
      case .editDialogLeft: CardlessPrompt.dialogLeft
      case .editRestartedThenDialogLeft: CardlessPrompt.dialogLeftAfterHookClosed
      case .notificationOnly: CardlessPrompt.notificationOnly
      }
    }
  }

  @Test(arguments: Cause.allCases)
  func eachCauseLeavesAnOpenPromptWithoutACard(_ cause: Cause) {
    let f = cause.sessionFacts

    #expect(f.cards.isEmpty)
    #expect(f.openPermission != nil || f.openQuestion != nil)
  }

  @Test(arguments: Cause.allCases)
  func eachCauseGivesItsReason(_ cause: Cause) {
    #expect(cause.sessionFacts.cardlessPromptReason == cause.reason)
  }

  @Test(arguments: Cause.allCases)
  func theVerdictsSummaryIsTheReason(_ cause: Cause) {
    let verdict = Attention.evaluate(session(), cause.sessionFacts, now: 30)

    #expect(verdict.summary == cause.reason)
  }

  @Test(arguments: Cause.allCases)
  func theInboxItemsSummaryIsTheReason(_ cause: Cause) {
    let f = cause.sessionFacts

    let item = Triage.liveItem(f, Attention.evaluate(session(), f, now: 30))

    #expect(item?.summary == cause.reason)
  }

  @Test func theVerdictOfARestartedFetchNamesTheTool() {
    let verdict = Attention.evaluate(session(), CardlessPrompt.restarted(fetchTurn()), now: 30)

    #expect(verdict.reason == "approve WebFetch")
  }

  @Test(arguments: [permissionTurn(), questionTurn(), editTurn()])
  func aFindableCardThatARestartKeepsGivesNoReason(_ turn: [Event]) {
    let f = CardlessPrompt.restarted(turn)

    #expect(f.cards.map(\.hookClosed) == [true])
    #expect(f.cardlessPromptReason == nil)
  }

  @Test func anOpenCardGivesNoSummary() {
    #expect(Attention.evaluate(session(), facts(permissionTurn()), now: 30).summary == nil)
  }

  @Test(arguments: [
    fetchTurn() + [
      event("card_closed", 4, ["card": 3]),
      event("PostToolUse", 5, tool("WebFetch", ["url": "https://example.com"], id: "f1")),
    ],
    editTurn() + [event("dialog_closed", 4, ["card": 3, "allowed": true])],
    permissionTurn() + [event("answered", 4, ["card": 3, "behavior": "allow"])],
  ])
  func noOpenPromptGivesNoReason(_ events: [Event]) {
    let f = facts(events)

    #expect(f.openPermission == nil && f.openQuestion == nil)
    #expect(f.cardlessPromptReason == nil)
  }

  static let bashRequest = Event(
    id: 5, session: "s1", t: 6, kind: "PermissionRequest", data: .object(tool("Bash", ["command": "ls"])))

  @Test func aNewPermissionRequestAfterARestartOpensACardWithoutAReason() {
    let f = CardlessPrompt.restarted(fetchTurn(), then: [CardlessPrompt.bashRequest])

    #expect(f.cards.map(\.id) == [5])
    #expect(f.cardlessPromptReason == nil)
  }

  /// The Bash call finishes, and a question opens before its card does. The
  /// fetch's cause must not explain that question.
  @Test func aNewPermissionRequestForgetsTheCauseOfTheCardBeforeIt() {
    let f = CardlessPrompt.restarted(
      fetchTurn(),
      then: [
        CardlessPrompt.bashRequest, event("PostToolUse", 7, tool("Bash", ["command": "ls"], id: "b2")),
        CardlessPrompt.questionWithoutACard,
      ])

    #expect(f.cards.isEmpty)
    #expect(f.cardlessPromptReason == CardlessPrompt.noCard)
  }

  @Test func aSubagentsPermissionRequestKeepsTheCause() {
    let call = tool("Bash", ["command": "ls"], agent: "a1")
    let request = Event(id: 5, session: "s1", t: 6, kind: "PermissionRequest", data: .object(call))

    let f = CardlessPrompt.restarted(fetchTurn(), then: [event("SubagentStart", 5, ["agent_id": "a1"]), request])

    #expect(f.cardlessPromptReason == CardlessPrompt.unreadable)
  }

  /// The Bash card's allow closes the prompt while the fetch's card stays.
  /// The restart then removes that card with no prompt open, so the question
  /// that opens next has no cause.
  @Test func aRestartWithNoOpenPromptLeavesNoCause() {
    let f = CardlessPrompt.restarted(
      fetchTurn() + [CardlessPrompt.bashRequest, event("answered", 6, ["card": 5, "behavior": "allow"])],
      then: [CardlessPrompt.questionWithoutACard])

    #expect(f.cards.isEmpty)
    #expect(f.cardlessPromptReason == CardlessPrompt.noCard)
  }

  @Test func aUserPromptAfterARestartLeavesNoReason() {
    let f = CardlessPrompt.restarted(fetchTurn(), then: [event("UserPromptSubmit", 6, ["prompt": "go on"])])

    #expect(f.cardlessPromptReason == nil)
  }

  @Test func aUserPromptForgetsTheCause() {
    let f = CardlessPrompt.restarted(
      fetchTurn(), then: [event("UserPromptSubmit", 6, ["prompt": "go on"]), CardlessPrompt.questionWithoutACard])

    #expect(f.cardlessPromptReason == CardlessPrompt.noCard)
  }

  /// The fetch finishes, a Notification opens a new prompt, and a tool
  /// finishing closes that prompt. The fetch's cause must not explain the
  /// question that opens next.
  @Test func aNotificationThatOpensANewPromptForgetsTheCause() {
    let f = facts(
      fetchTurn() + [
        event("card_closed", 4, ["card": 3]),
        event("PostToolUse", 5, tool("WebFetch", ["url": "https://example.com"], id: "f1")),
        CardlessPrompt.permissionNotification, event("PostToolUse", 11, tool("Bash", ["command": "ls"], id: "b2")),
        CardlessPrompt.questionWithoutACard,
      ])

    #expect(f.cardlessPromptReason == CardlessPrompt.noCard)
  }

  @Test func aQuestionWithoutACardYetHasTheNoCardReason() {
    let f = facts([event("UserPromptSubmit", 0, ["prompt": "go"]), CardlessPrompt.questionWithoutACard])

    #expect(f.cardlessPromptReason == CardlessPrompt.noCard)
  }

  @Test func aCardThatLeavesBecauseItsDialogLeftReplacesAnEarlierCause() {
    let f = CardlessPrompt.restarted(
      fetchTurn(),
      then: [
        CardlessPrompt.bashRequest, event("card_closed", 7, ["card": 5]), event("dialog_closed", 8, ["card": 5]),
      ])

    #expect(f.cardlessPromptReason == CardlessPrompt.dialogLeftAfterHookClosed)
  }
}

/// A subagent holds the session only while subagent events
/// keep arriving. Activity that has nothing to do with the subagent does not
/// extend the hold.
@Suite struct SubagentBound {
  static let quiet = Attention.subagentQuietMs
  static let twentyMinutes: Int64 = 20 * 60_000
  static let reply = "I'll wait for the review."

  /// A turn that started subagent a1 at t = 1 and ended at t = 2.
  let started = [
    event("UserPromptSubmit", 0, ["prompt": "go"]),
    event("SubagentStart", 1, ["agent_id": "a1"]),
    event("Stop", 2, ["last_assistant_message": .string(SubagentBound.reply)]),
  ]

  /// An event of `kind` that the user, sbd, or the session caused, which moves `lastActivity`.
  static func unrelated(_ kind: String, _ t: Int64) throws -> Event {
    switch kind {
    case "ack": return event("ack", t, ["state": "needs_you", "reason": "read its last reply and decide what's next"])
    case "note": return event("note", t, ["note": try JSON(encoding: Note(id: "n1", text: "x", by: .you, t: t))])
    case "sent": return event("sent", t, ["text": "hi", "delivery": "queued"])
    case "wait": return event("wait", t, ["wait": try JSON(encoding: waitOn(.ci))])
    default: return event(kind, t)
    }
  }

  @Test func noSubagentEventLeavesItUnset() {
    #expect(facts([event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1)]).lastSubagentEvent == nil)
  }

  @Test func subagentStartSetsTheLastSubagentEvent() {
    #expect(facts([event("SubagentStart", 5, ["agent_id": "a1"])]).lastSubagentEvent == 5)
  }

  @Test func subagentStopSetsTheLastSubagentEvent() {
    let f = facts([event("SubagentStart", 5, ["agent_id": "a1"]), event("SubagentStop", 8, ["agent_id": "a1"])])

    #expect(f.lastSubagentEvent == 8)
  }

  @Test(arguments: ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"])
  func subagentHookSetsTheLastSubagentEvent(_ kind: String) {
    let f = facts([
      event("SubagentStart", 5, ["agent_id": "a1"]),
      event(kind, 7, tool("Bash", ["command": "ls"], id: "t1", agent: "a1")),
    ])

    #expect(f.lastSubagentEvent == 7)
  }

  @Test(arguments: ["ack", "note", "sent", "wait", "answered", "unack"])
  func unrelatedActivityLeavesTheLastSubagentEvent(_ kind: String) throws {
    let f = facts([event("SubagentStart", 5, ["agent_id": "a1"]), try Self.unrelated(kind, 9)])

    #expect(f.lastSubagentEvent == 5)
  }

  @Test func mainSessionToolCallLeavesTheLastSubagentEvent() {
    let f = facts([
      event("SubagentStart", 5, ["agent_id": "a1"]), event("PreToolUse", 9, tool("Bash", ["command": "ls"], id: "t1")),
    ])

    #expect(f.lastSubagentEvent == 5)
  }

  @Test func subagentHoldsTheSessionForItsQuietTime() {
    let v = Attention.evaluate(session(), facts(started), now: 1 + Self.quiet)

    #expect(v == Verdict(state: .waiting, reason: "waiting on 1 subagent"))
  }

  @Test func subagentStopsHoldingAMillisecondAfterItsQuietTime() {
    #expect(Attention.evaluate(session(), facts(started), now: 1 + Self.quiet + 1).state == .needsYou)
  }

  @Test(arguments: ["ack", "note", "sent", "wait"])
  func unrelatedActivityDoesNotExtendTheHold(_ kind: String) throws {
    let f = facts(started + [try Self.unrelated(kind, 1 + Self.twentyMinutes)])

    #expect(Attention.evaluate(session(), f, now: 1 + Self.quiet + 1).state == .needsYou)
  }

  @Test func severalUnrelatedEventsDoNotExtendTheHold() throws {
    let later = try ["ack", "note", "sent", "wait"].enumerated().map { i, kind in
      try Self.unrelated(kind, 1 + Int64(i + 1) * 5 * 60_000)
    }

    let v = Attention.evaluate(session(), facts(started + later), now: 1 + Self.quiet + 1)

    #expect(v.state == .needsYou)
  }

  @Test func subagentToolCallExtendsTheHold() {
    let call = event("PreToolUse", 1 + Self.twentyMinutes, tool("Bash", ["command": "ls"], id: "t1", agent: "a1"))

    let v = Attention.evaluate(session(), facts(started + [call]), now: 1 + Self.quiet + 1)

    #expect(v.state == .waiting)
  }

  @Test func subagentToolCallHoldsForItsQuietTimeOnly() {
    let at = 1 + Self.twentyMinutes
    let call = event("PreToolUse", at, tool("Bash", ["command": "ls"], id: "t1", agent: "a1"))

    #expect(Attention.evaluate(session(), facts(started + [call]), now: at + Self.quiet + 1).state == .needsYou)
  }
}

/// An approved PR that every ready-to-merge condition passes, in a repository
/// that sbd merges with a merge commit.
private func approvedLandablePR(_ edit: (inout PullRequest) -> Void = { _ in }) -> PullRequest {
  var pr = samplePR(
    reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")], checks: "SUCCESS", reviewRequests: [])
  pr.trunkConfig = false
  pr.mergeQueue = false
  pr.inMergeQueue = false
  pr.reviewDecisionRead = true
  edit(&pr)
  return pr
}

/// Each concrete cause of Waiting that `Attention.rules` knows.
enum WaitingCause: String, CaseIterable, Sendable {
  case openWait, subagent, backgroundJob, jobReport, mergedNotYetRead, mergeQueue, checksRunning
  case mergeabilityUnknown, busyStackBase, openDependency, paused

  static let now: Int64 = 10_000
  static let reply = "I'll wait for it."

  /// The session's verdict at `now`, with the cause or without it.
  func verdict(withCause: Bool) throws -> Verdict {
    let turn = [
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("Stop", 1, ["last_assistant_message": .string(WaitingCause.reply)]),
    ]
    var s = session()
    var events = turn
    var stateOf: (String) -> AttentionState? = { _ in nil }
    switch self {
    case .openWait:
      if withCause { s = session(wait: "CI on #12") }
    case .subagent:
      if withCause { events.insert(event("SubagentStart", 0, ["agent_id": "a1"]), at: 1) }
    case .backgroundJob:
      if withCause { events.append(event("job", 2, ["count": 1])) }
    case .jobReport:
      if withCause {
        events += [event("job", 2, ["count": 1]), event("job", WaitingCause.now - 1, ["count": 0])]
      }
    case .mergedNotYetRead:
      events.append(try prEvent(2, approvedLandablePR()))
      if withCause { events.append(mergeEvent(3, head: samplePRHead, "merged")) }
    case .mergeQueue:
      events.append(try prEvent(2, approvedLandablePR { $0.inMergeQueue = withCause }))
    case .checksRunning:
      events.append(try prEvent(2, approvedLandablePR { $0.checks = withCause ? "PENDING" : "SUCCESS" }))
    case .mergeabilityUnknown:
      events.append(try prEvent(2, approvedLandablePR { $0.mergeable = withCause ? .unknown : .mergeable }))
    case .busyStackBase:
      events.append(try prEvent(2, approvedLandablePR { $0.mergeable = .conflicting }))
      let base = Dependency(
        via: .stack, repo: "acme/widgets", number: 41, base: "haacked/base", state: .open, session: "s2")
      events.append(try dependenciesEvent(3, [base]))
      stateOf = { $0 == "s2" ? (withCause ? .working : .needsYou) : nil }
    case .openDependency:
      events.append(try prEvent(2, samplePR(reviewDecision: .approved, verdicts: [sampleVerdict("alice", "APPROVED")])))
      if withCause {
        events.append(
          try dependenciesEvent(3, [Dependency(via: .body, repo: "acme/widgets", number: 41, state: .open)]))
      }
    case .paused:
      if withCause { s.pause = pauseOf() }
    }
    return Attention.evaluate(s, facts(events), now: WaitingCause.now, stateOf: stateOf)
  }
}

/// A session is in Waiting only while a concrete cause holds it.
@Suite struct WaitingNeedsACause {
  @Test(arguments: WaitingCause.allCases)
  func causeGivesWaiting(_ cause: WaitingCause) throws {
    #expect(try cause.verdict(withCause: true).state == .waiting)
  }

  @Test(arguments: WaitingCause.allCases)
  func sameFactsWithoutTheCauseAreNotWaiting(_ cause: WaitingCause) throws {
    #expect(try cause.verdict(withCause: false).state != .waiting)
  }

  /// manager-redesign (sni5dx) had none of the causes. Only its acknowledgment held it in Waiting.
  @Test func sni5dxFactsWithoutTheAcknowledgmentNeedYou() {
    let f = facts(sni5dxEvents(acknowledged: false))

    let v = Attention.evaluate(session(), f, now: sni5dxAck + 59 * 60_000)

    #expect(v == Verdict(state: .needsYou, reason: "read its last reply and decide what's next"))
  }
}

/// A session in a state that some rule gives, which a pause must override.
enum PausedShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case firstPrompt, runningTurn, openCard, deferredCard, openPermission, openQuestion, questionReply, offer
  case openWait, overdueWait, notifyOutcome, readyToMerge, openPR, requestHold, unreadHost, stale

  var testDescription: String { rawValue }

  static let conflictReason = "merge main in; #42 conflicts with main"

  var now: Int64 { self == .stale ? Attention.staleAfterMs + 10 : 10_500 }

  /// The state that the session has without the pause, which shows that the shape reaches its rule.
  var unpausedState: AttentionState {
    switch self {
    case .runningTurn: .working
    case .offer: .canContinue
    case .openWait, .requestHold: .waiting
    case .readyToMerge: .readyToMerge
    case .openPR: .readyForReview
    case .stale: .stale
    case .firstPrompt, .openCard, .deferredCard, .openPermission, .openQuestion, .questionReply, .overdueWait,
      .notifyOutcome, .unreadHost:
      .needsYou
    }
  }

  /// The session with the pause, or without one when `pause` is nil.
  func subject(_ pause: Pause?) -> Session {
    var s = session()
    switch self {
    case .openWait: s.waits = [Wait(id: "w1", kind: .ci, pr: pr1204, created: 0)]
    case .overdueWait: s.waits = [Wait(id: "w1", kind: .ci, pr: pr1204, created: 0, recheck: 5_000)]
    case .openPR: s.waits = [Wait(id: "w1", kind: .manual, note: "the deploy of #42", created: 0, then: .notify)]
    case .unreadHost: s.host = "mini"
    default: break
    }
    s.pause = pause
    return s
  }

  func shapeFacts() throws -> SessionFacts {
    func turn(_ reply: String) -> [Event] {
      [event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": .string(reply)])]
    }
    switch self {
    case .firstPrompt:
      return facts([event("SessionStart", 1)])
    case .runningTurn:
      return facts([event("UserPromptSubmit", 0, ["prompt": "go"])])
    case .openCard, .deferredCard:
      var f = facts(turn("All tests pass."))
      var card = Card(event("PermissionRequest", 3, tool("Bash", ["command": "ls"])))
      card.deferred = self == .deferredCard
      f.cards = [card]
      return f
    case .openPermission:
      return facts([
        event("UserPromptSubmit", 0, ["prompt": "go"]),
        event("PreToolUse", 1, tool("Bash", ["command": "rm -rf build"], id: "x")),
        event("PermissionRequest", 2, tool("Bash", ["command": "rm -rf build"])),
      ])
    case .openQuestion:
      return facts([
        event("UserPromptSubmit", 0, ["prompt": "go"]),
        event("PreToolUse", 1, tool("AskUserQuestion", ["questions": [["question": "Which fruit?"]]], id: "q")),
      ])
    case .questionReply:
      return facts(turn("Which base should it target?"))
    case .offer:
      return facts(turn("Want me to push the fix?"))
    case .openWait, .overdueWait, .stale:
      return facts(turn("All tests pass."))
    case .notifyOutcome:
      return facts(
        turn("All tests pass.") + [try resolved(waitOn(.ci, pr: pr1204, then: .notify), "the checks passed", 2)])
    case .readyToMerge:
      return try prFacts(readyPR())
    case .openPR:
      return try prFacts(readyPR(reviewDecision: .reviewRequired))
    case .requestHold:
      let request = event(
        InboxRequest.event, 10_000,
        [
          "state": "needs_you", "reason": .string(PausedShape.conflictReason), "head": .string(samplePRHead),
          "message": "Merge origin/main into this branch.", "until": .number(Double(10_000 + 3_600_000)),
          "readMs": 60_000,
        ])
      return try prFacts(samplePR(mergeable: .conflicting), then: [request])
    case .unreadHost:
      return facts(
        turn("Which base should it target?") + [
          event("link_down", 3, ["host": "mini", "link": "unreachable", "error": "ssh: connect to host mini.local"])
        ])
    }
  }
}

/// A paused session that isn't marked done is Waiting with the pause's line, whatever else holds it.
@Suite struct PausedAttentionTests {
  static let pause = pauseOf(by: .claude, from: managerPauser, reason: "free CPU for flags")

  @Test(arguments: PausedShape.allCases)
  func withoutThePauseTheShapeReachesItsRule(_ shape: PausedShape) throws {
    let v = Attention.evaluate(shape.subject(nil), try shape.shapeFacts(), now: shape.now)

    #expect(v.state == shape.unpausedState, "\(v)")
  }

  @Test func withoutThePauseTheRequestHoldsTheSession() throws {
    let shape = PausedShape.requestHold

    let v = Attention.evaluate(shape.subject(nil), try shape.shapeFacts(), now: shape.now)

    #expect(v.requested)
  }

  @Test(arguments: PausedShape.allCases)
  func evaluateGivesWaitingWithThePauseLine(_ shape: PausedShape) throws {
    let v = Attention.evaluate(shape.subject(Self.pause), try shape.shapeFacts(), now: shape.now)

    #expect(v == Verdict(state: .waiting, reason: "Paused by Manager: free CPU for flags"))
  }

  @Test(arguments: PausedShape.allCases)
  func unheldGivesWaitingWithThePauseLine(_ shape: PausedShape) throws {
    let v = Attention.unheld(shape.subject(Self.pause), try shape.shapeFacts(), now: shape.now)

    #expect(v == Verdict(state: .waiting, reason: Self.pause.line))
  }

  @Test(arguments: PausedShape.allCases)
  func thePausedVerdictIsInfo(_ shape: PausedShape) throws {
    let v = Attention.evaluate(shape.subject(Self.pause), try shape.shapeFacts(), now: shape.now)

    #expect(v.kind == .info)
  }

  @Test(arguments: PausedShape.allCases)
  func thePausedVerdictIsNotARequestHold(_ shape: PausedShape) throws {
    let v = Attention.evaluate(shape.subject(Self.pause), try shape.shapeFacts(), now: shape.now)

    #expect(!v.requested)
  }

  @Test(arguments: PausedShape.allCases)
  func doneOutranksThePause(_ shape: PausedShape) throws {
    var s = shape.subject(Self.pause)
    s.done = true

    let v = Attention.evaluate(s, try shape.shapeFacts(), now: shape.now)

    #expect(v == Verdict(state: .done, reason: "marked done"))
  }

  @Test(arguments: [true, false])
  func aPausedManagerOrChatIsWaitingWithThePauseLine(_ manager: Bool) throws {
    var s = PausedShape.questionReply.subject(Self.pause)
    if manager { s.manager = true } else { s.chat = "g1" }

    let v = Attention.evaluate(s, try PausedShape.questionReply.shapeFacts(), now: 10)

    #expect(v == Verdict(state: .waiting, reason: Self.pause.line))
  }

  /// An acknowledgment moves only an Inbox verdict, so it leaves the paused verdict as it is.
  @Test func anAcknowledgedItemStaysPaused() throws {
    let readTheReply = "read its last reply and decide what's next"
    let ack = try JSON(encoding: Acknowledgment(state: .needsYou, reason: readTheReply, head: nil))
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "All tests pass."]),
      event("ack", 2, ack.object ?? [:]),
    ])
    let acknowledgedMs = RecheckSettings().acknowledgedMs
    let unpaused = Attention.shown(
      Attention.evaluate(session(), f, now: 10), f, now: 10, acknowledgedMs: acknowledgedMs)
    try #require(unpaused.acknowledged, "the acknowledgment didn't hold the unpaused session: \(unpaused)")

    let v = Attention.shown(
      Attention.evaluate(pausedSession(Self.pause), f, now: 10), f, now: 10, acknowledgedMs: acknowledgedMs)

    #expect(v == Verdict(state: .waiting, reason: Self.pause.line))
    #expect(!v.acknowledged)
  }

  @Test func trackRecordsWaitingForAPausedSession() throws {
    var f = try PausedShape.questionReply.shapeFacts()

    Attention.track(pausedSession(Self.pause), &f, now: 10)

    #expect(f.lastState == .waiting)
  }
}

@Suite struct RemovalAttentionTests {
  /// Short enough that a reason that `oneLine` shortens to 70 characters keeps it whole.
  static let message = "/tmp/w has uncommitted files (1)."

  /// A stored session with a removal in `state`, decoded as sbd decodes the store.
  static func session(removal state: String, done: Bool = false) throws -> Session {
    let json: JSON = [
      "id": "s1", "name": "test", "cwd": "/tmp/w", "claudeSessionId": "uuid", "created": 0, "started": true,
      "done": .bool(done),
      "removal": [
        "state": .string(state), "requested": 1, "notBefore": 1, "worktree": true, "branch": false,
        "remoteBranch": false, "released": false, "resolve": [], "error": state == "failed" ? .string(message) : .null,
      ],
    ]
    let s = try JSONCoding.decode(Session.self, from: json.text)
    try #require(s.removal != nil)
    return s
  }

  /// Delete All takes Done sessions: one the user marked done, and one whose PR merged. A failed removal must move
  /// each to Needs you, or the failure never reaches the Inbox.
  @Test(arguments: ["plain", "marked done", "merged PR"])
  func aFailedRemovalNeedsYouWithTheError(_ kind: String) throws {
    let s = try Self.session(removal: "failed", done: kind == "marked done")
    let f =
      kind == "merged PR"
      ? try prFacts(samplePR(state: .merged), dirty: 0)
      : facts([event("UserPromptSubmit", 0, ["prompt": "go"]), event("Stop", 1, ["last_assistant_message": "Done."])])

    let verdict = Attention.evaluate(s, f, now: 10)

    #expect(verdict == Verdict(state: .needsYou, reason: "Delete failed: \(Self.message)"))
  }
}

/// The operator's ask verdict for reports that sbd could not route to another session. It nests under
/// `TriageOperatorTests`, so that suite's filter runs it.
extension TriageOperatorTests {
  @Suite struct ReportVerdicts {
    /// The operator's verdict with no Manager conversation, so its open reports and waits stay on it.
    func verdict(_ events: [Event], waits: [Wait] = []) -> Verdict {
      let s = operatorSession(waits: waits)
      return Attention.evaluate(s, opRouted(s, facts(events)), now: 1000)
    }

    @Test func anOpenReportPutsTheOperatorInNeedsYouWithItsText() {
      let v = verdict(opIdle + [opReport(10, "PR #12 is green. Merge it?")])

      #expect(v == Verdict(state: .needsYou, reason: "Operator: PR #12 is green. Merge it?"))
    }

    @Test(
      arguments: [
        (2, "Operator: b (and 1 more)"), (3, "Operator: c (and 2 more)"), (4, "Operator: d (and 3 more)"),
      ] as [(Int, String)])
    func severalOpenReportsGiveTheLatestTextAndTheCountOfTheRest(_ count: Int, _ reason: String) {
      let texts = ["a", "b", "c", "d"].prefix(count)
      let reports = texts.enumerated().map { opReport(Int64(10 + $0.offset), $0.element) }

      let v = verdict(opIdle + reports)

      #expect(v == Verdict(state: .needsYou, reason: reason))
    }

    @Test func aClosedReportLeavesTheCount() {
      let v = verdict(opIdle + [opReport(10, "a"), opAck(11), opReport(12, "b")])

      #expect(v == Verdict(state: .needsYou, reason: "Operator: b"))
    }

    @Test func aReportWithoutNeedsYouGivesNoReportVerdict() {
      let v = verdict(opIdle + [opReport(10, "Removed the kid's worktree.", needsYou: false)])

      #expect(!v.reason.contains("Removed the kid's worktree."))
    }

    /// What the operator holds besides its report, which the ask verdict comes before.
    enum Beside: CaseIterable, Sendable {
      case openWait, overdueWait, notifyOutcome, questionReply, offerReply, informationalReply, noPrompt, runningTurn

      func events() throws -> [Event] {
        switch self {
        case .openWait, .overdueWait, .informationalReply: opIdle
        case .notifyOutcome: opIdle + [try opNotified(5)]
        case .questionReply: [opPrompt(1, "go"), stop(2, 2, proseQuestion)]
        case .offerReply: [opPrompt(1, "go"), stop(2, 2, "I removed the worktree. Want me to top up the queue?")]
        case .noPrompt: []
        case .runningTurn: [opPrompt(1, "go")]
        }
      }

      var waits: [Wait] {
        switch self {
        case .openWait: [SwitchboardCoreTests.openWait]
        case .overdueWait: [SwitchboardCoreTests.overdueWait]
        default: []
        }
      }
    }

    @Test(arguments: Beside.allCases)
    func theAskVerdictComesBeforeTheWorkingWaitAndReplyVerdicts(_ beside: Beside) throws {
      let without = verdict(try beside.events(), waits: beside.waits)
      try #require(without.reason != "Operator: Merge it?")

      let v = verdict(try beside.events() + [opReport(10, "Merge it?")], waits: beside.waits)

      #expect(v == Verdict(state: .needsYou, reason: "Operator: Merge it?"))
    }

    @Test func aReportMadeAfterTheUsersMessageStillWins() {
      let v = verdict(opIdle + [opUserSent(9, "go on")] + opTurn(10, "go on") + [opReport(20, "Merge it?")])

      #expect(v == Verdict(state: .needsYou, reason: "Operator: Merge it?"))
    }

    @Test func aReportClosedByTheUsersMessageLeavesTheOperatorIdle() {
      let v = verdict(opIdle + [opReport(10, "Merge it?"), opUserSent(11, "yes")] + opTurn(12, "yes"))

      #expect(v == Verdict(state: .waiting, reason: "idle"))
    }

    @Test func aReportClosedByAckGivesTheHeldWaitVerdictAgain() {
      let v = verdict(opIdle + [opReport(10, "Merge it?"), opAck(11)], waits: [overdueWait])

      #expect(
        v == Verdict(state: .needsYou, reason: "Background follow-through still waits: \(overdueWait.overdueLine)"))
      #expect(v.fromOperator)
    }

    /// Report events route nothing on their own. Another kind gives the same verdict with or without them.
    @Test(arguments: [SessionKind.work, .manager, .chat]) func anotherKindIgnoresReports(_ kind: SessionKind) {
      let events = opIdle + [opReport(10, "Merge it?")]

      let v = Attention.evaluate(kindSession(kind), facts(events), now: 1000)

      #expect(v == Attention.evaluate(kindSession(kind), facts(opIdle), now: 1000))
      #expect(!v.reason.contains("Merge it?"))
    }
  }
}

/// `SessionFacts.contextTokens`, the input context of a Manager conversation's latest turn. sbd records a `context`
/// event after each turn, and a `/clear` or a compaction starts a context that the old value doesn't describe.
@Suite struct ConversationContextFoldTests {
  @Test func noContextEventLeavesTheTokensUnset() {
    #expect(facts([event("SessionStart", 0), event("Stop", 1)]).contextTokens == nil)
  }

  @Test func aContextEventSetsTheTokens() {
    let f = facts([event("Stop", 1), event("context", 2, ["tokens": 250_000])])

    #expect(f.contextTokens == 250_000)
  }

  @Test func aLaterContextEventReplacesTheTokens() {
    let f = facts([event("context", 2, ["tokens": 250_000]), event("context", 4, ["tokens": 90_000])])

    #expect(f.contextTokens == 90_000)
  }

  /// sbd records null when a read finds no value while one is stored, as after a compaction without a turn since.
  @Test func aContextEventWithNullTokensClearsThem() {
    let f = facts([event("context", 2, ["tokens": 250_000]), event("context", 4, ["tokens": .null])])

    #expect(f.contextTokens == nil)
  }

  @Test func aContextEventLeavesTheLastActivity() {
    let f = facts([event("Stop", 1), event("context", 500, ["tokens": 250_000])])

    #expect(f.lastActivity == 1)
  }

  @Test(arguments: ["clear", "compact"])
  func aSessionStartOfANewContextClearsTheTokens(_ source: String) {
    let f = facts([event("context", 2, ["tokens": 250_000]), event("SessionStart", 3, ["source": .string(source)])])

    #expect(f.contextTokens == nil)
  }

  @Test func aSessionStartThatResumesKeepsTheTokens() {
    let f = facts([event("context", 2, ["tokens": 250_000]), event("SessionStart", 3, ["source": "resume"])])

    #expect(f.contextTokens == 250_000)
  }

  @Test func aContextEventAfterAClearSetsTheTokensAgain() {
    let f = facts([
      event("context", 2, ["tokens": 250_000]), event("SessionStart", 3, ["source": "clear"]),
      event("context", 5, ["tokens": 12_000]),
    ])

    #expect(f.contextTokens == 12_000)
  }
}

/// The sessions that a Manager conversation spawned, folded from the conversation's own events: `child` when it
/// created one, `linked` when `sb parent` linked one in, and `unlinked` when `sb parent --clear` took one out. The
/// set keeps a child after its removal. `end-hint-dismissed` records the key of the hint that the user dismissed.
@Suite struct ConversationSpawnFoldTests {
  @Test func noEventsLeaveNothingSpawnedAndNothingDismissed() {
    let f = facts([event("SessionStart", 0), event("Stop", 1)])

    #expect(f.spawned.isEmpty)
    #expect(f.endHintDismissed == nil)
  }

  @Test func aChildEventAddsTheChild() {
    #expect(facts([event("child", 2, ["child": "k1"])]).spawned == ["k1"])
  }

  @Test func aLinkedEventWithAChildAddsTheChild() {
    #expect(facts([event("linked", 2, ["child": "k1", "by": "you"])]).spawned == ["k1"])
  }

  /// sbd records `linked` on the child too, with `parent` and no `child`. The child spawned nothing.
  @Test func aLinkedEventThatNamesOnlyAParentAddsNothing() {
    #expect(facts([event("linked", 2, ["parent": "m1", "by": "you"])]).spawned.isEmpty)
  }

  @Test func anUnlinkedEventRemovesTheChild() {
    let f = facts([
      event("child", 2, ["child": "k1"]), event("child", 3, ["child": "k2"]),
      event("unlinked", 4, ["child": "k1", "by": "you"]),
    ])

    #expect(f.spawned == ["k2"])
  }

  @Test func anUnlinkedEventThatNamesOnlyAParentRemovesNothing() {
    let f = facts([event("child", 2, ["child": "k1"]), event("unlinked", 4, ["parent": "m1", "by": "you"])])

    #expect(f.spawned == ["k1"])
  }

  @Test func theDismissedEventRecordsTheKey() {
    #expect(facts([event("end-hint-dismissed", 2, ["key": "done:1"])]).endHintDismissed == "done:1")
  }

  @Test func aLaterDismissalReplacesTheKey() {
    let f = facts([
      event("end-hint-dismissed", 2, ["key": "context:2"]), event("end-hint-dismissed", 4, ["key": "context:3"]),
    ])

    #expect(f.endHintDismissed == "context:3")
  }

  /// None of these kinds moves `lastActivity`, so none holds off the idle stop or brings back an archived
  /// conversation.
  @Test(arguments: [
    event("child", 500, ["child": "k1"]), event("linked", 500, ["child": "k1", "by": "you"]),
    event("unlinked", 500, ["child": "k1", "by": "you"]), event("end-hint-dismissed", 500, ["key": "done:1"]),
    event("context", 500, ["tokens": 250_000]),
  ])
  func aConversationEventLeavesTheLastActivity(_ e: Event) {
    #expect(facts([event("Stop", 1), e]).lastActivity == 1)
  }
}

/// A `skill_blocked` event ends the turn that a blocked prompt started, because Claude Code sends no Stop after a
/// UserPromptSubmit block. A blocked tool call clears the running tool and leaves the turn running.
@Suite struct SkillBlockedAttentionTests {
  private func blocked(_ via: String, _ t: Int64) -> Event {
    event("skill_blocked", t, ["skill": "go", "via": .string(via), "by": "haiku"])
  }

  private let skillCall = tool("Skill", ["skill": "go"], id: "s1")

  @Test func aBlockedPromptEndsItsTurn() {
    let f = facts([event("SessionStart", 0), event("UserPromptSubmit", 1, ["prompt": "/go x"]), blocked("prompt", 2)])

    #expect(!f.turnRunning)
    #expect(Attention.evaluate(session(), f, now: 3).state != .working)
  }

  @Test func aBlockedToolCallClearsTheRunningToolAndKeepsTheTurn() {
    let f = facts([
      event("UserPromptSubmit", 1, ["prompt": "load go"]), event("PreToolUse", 2, skillCall), blocked("tool", 3),
    ])

    #expect(f.turnRunning)
    #expect(f.runningTool == nil)
  }

  /// A subagent's Skill call never became the running tool, so its block leaves the main session's Agent call.
  @Test func aSubagentsBlockedSkillCallKeepsTheMainSessionsRunningTool() {
    let f = facts([
      event("UserPromptSubmit", 1, ["prompt": "review it"]),
      event("PreToolUse", 2, tool("Agent", ["prompt": "load go"], id: "a1")),
      event("PreToolUse", 3, tool("Skill", ["skill": "go"], id: "s1", agent: "sub1")),
      blocked("tool", 4),
    ])

    #expect(f.turnRunning)
    #expect(f.runningTool?.tool == "Agent")
  }

  @Test func aBlockedPromptAfterAnEndedTurnChangesNothing() {
    let ended = [event("UserPromptSubmit", 1, ["prompt": "hi"]), event("Stop", 2, ["last_assistant_message": "Hi."])]

    let f = facts(ended + [blocked("prompt", 3)])

    #expect(!f.turnRunning)
    #expect(f.lastReply == "Hi.")
  }
}

/// `SessionFacts.promptOnItsWaySince`, which a restarted sbd reads to count a prompt that claude has not submitted
/// as a message on its way.
@Suite struct PromptOnItsWayFoldTests {
  static let text = "the deploy finished"

  static func pasting(_ t: Int64, _ text: String = text) -> Event { event("pasting", t, ["text": .string(text)]) }
  static func delivered(_ t: Int64, _ text: String = text) -> Event { event("delivered", t, ["text": .string(text)]) }
  static func submit(_ t: Int64) -> Event { event("UserPromptSubmit", t, ["prompt": .string(text)]) }
  static let ready = [event("resumed", 0, ["prompt": .null]), event("SessionStart", 100)]

  @Test func aLaunchWithAPromptSetsTheLaunchsTime() {
    #expect(facts([event("resumed", 50, ["prompt": .string(Self.text)])]).promptOnItsWaySince == 50)
  }

  @Test func aLaunchWithoutAPromptSetsNothing() {
    #expect(facts(Self.ready).promptOnItsWaySince == nil)
  }

  @Test func theLaunchsSessionStartMovesTheTime() {
    let f = facts([event("resumed", 50, ["prompt": .string(Self.text)]), event("SessionStart", 80)])

    #expect(f.promptOnItsWaySince == 80)
  }

  /// `pasting` reaches the log before the paste starts, so its time is in the past at any later restart.
  @Test func aPasteSetsThePastingTimeAndDeliveredKeepsIt() {
    #expect(facts(Self.ready + [Self.pasting(200)]).promptOnItsWaySince == 200)
    #expect(facts(Self.ready + [Self.pasting(200), Self.delivered(210)]).promptOnItsWaySince == 200)
  }

  @Test func theSubmitClearsAPaste() {
    let f = facts(Self.ready + [Self.pasting(200), Self.delivered(210), Self.submit(300)])

    #expect(f.promptOnItsWaySince == nil)
  }

  /// The hook can reach sbd before the paste's `delivered` does.
  @Test func aSubmitBeforeDeliveredLeavesNothingOnItsWay() {
    let f = facts(Self.ready + [Self.pasting(200), Self.submit(205), Self.delivered(210)])

    #expect(f.promptOnItsWaySince == nil)
  }

  @Test(arguments: ["/compact", "/clear", "/model opus"])
  func aBuiltInCommandsPasteSetsNothing(_ command: String) {
    let f = facts(Self.ready + [Self.pasting(200, command), Self.delivered(210, command)])

    #expect(f.promptOnItsWaySince == nil)
  }

  /// A skill sends a prompt, so its UserPromptSubmit confirms it as for any other message.
  @Test func aSkillsPasteSetsTheTime() {
    #expect(facts(Self.ready + [Self.pasting(200, "/code-review")]).promptOnItsWaySince == 200)
  }

  /// `requeued` puts the message back in the queue, which counts it from then on.
  @Test func aRequeueClearsAPaste() {
    let f = facts(Self.ready + [Self.pasting(200), event("requeued", 210, ["text": .string(Self.text)])])

    #expect(f.promptOnItsWaySince == nil)
  }

  @Test func aLaterLaunchWithoutAPromptClearsAPaste() {
    let f = facts(Self.ready + [Self.pasting(200), event("exited", 250), event("resumed", 300, ["prompt": .null])])

    #expect(f.promptOnItsWaySince == nil)
  }
}
