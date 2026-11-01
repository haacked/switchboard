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

  @Test func turnEndedWithASubagentRunningIsWorking() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "go"]),
      event("SubagentStart", 1, ["agent_id": "a1"]),
      event("Stop", 2, ["last_assistant_message": "I'll wait for the review."]),
    ])
    #expect(Attention.evaluate(session(), f, now: 3) == Verdict(state: .working, reason: "waiting on 1 subagent"))
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

  @Test func subagentResultPromptsDontCountAsPrompts() {
    let f = facts([
      event("UserPromptSubmit", 0, ["prompt": "<agent-message from=\"a1\"> [Subagent hand-back] done"]),
      event("UserPromptSubmit", 1, ["prompt": "<task-notification><task-id>a1</task-id></task-notification>"]),
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
  ])
  func classifies(_ reply: String, _ kind: ReplyKind) {
    #expect(Attention.classify(reply) == kind)
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
