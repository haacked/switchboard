import Foundation
import SwitchboardCore
import Testing

/// The Claude Code adapter against the installed claude with Haiku. Each test
/// also records the hook payloads of the steps it ran, which the stub plays.
/// The tests run one at a time, so they hold one live claude at once.
@Suite(.enabled(if: ClaudeTier.enabled, "bin/test --claude runs it"), .serialized, .timeLimit(.minutes(3)))
struct ClaudeTests {
  @Test func startsWithAPromptAndTakesAPastedMessage() throws {
    let c = try ClaudeInstance()
    let prompt = "Reply with \(c.nonce)-A and nothing else."
    let s = try c.sbd.new(prompt: prompt)
    let first = try c.waitFor(s.id, "the first reply") { $0.lastReply?.contains("\(c.nonce)-A") == true }
    #expect(first.state == .needsYou)
    let start = try #require(try c.sbd.hooks(s.id).first { $0.kind == "SessionStart" })
    let submit = try #require(try c.sbd.hooks(s.id).first { $0.kind == "UserPromptSubmit" })
    #expect(start.data["session_id"]?.string == s.claudeSessionId)
    #expect(start.data["source"]?.string == "startup")
    #expect(start.data["model"]?.string?.contains("haiku") == true)
    #expect(submit.data["prompt"]?.string == prompt)
    try c.waitFor(s.id, "claude's pid") { $0.claudePid != nil }

    // The header names the session's Remote Control link, and the transcript
    // records the connection as a bridge-session line.
    let screen = try c.screen(s.id)
    #expect(screen.contains("Claude Code v"))
    #expect(!screen.contains(" · /rc"))
    let transcript = try String(contentsOfFile: try #require(start.data["transcript_path"]?.string), encoding: .utf8)
    #expect(!transcript.split(separator: "\n").contains { JSON.parse(String($0))?["type"] == "bridge-session" })

    try c.settle(s.id)
    let mark = try c.lastEventId(s.id)
    let text = "Reply with \(c.nonce)-B and nothing else."
    #expect(try c.sbd.sb("send", s.id, text) == "pasted\n")
    try c.waitFor(s.id, "the pasted message's reply") { $0.lastReply?.contains("\(c.nonce)-B") == true }
    try c.settle(s.id)
    try c.record("startup", s.id, after: 0, through: submit.id - 1)
    try c.record("turn", s.id, after: mark, prompts: [text])
  }

  @Test func pastesALongMessageAndQueuesTheNextOne() throws {
    let c = try ClaudeInstance()
    let s = try c.sbd.new(prompt: "Reply with READY and nothing else.")
    try c.waitFor(s.id, "the first reply") { $0.lastReply != nil }
    try c.settle(s.id)
    let mark = try c.lastEventId(s.id)
    // tmux strips a trailing semicolon from a command argument, and an Enter
    // inside a paste must not submit the message early.
    let first = "Reply with \(c.nonce)-A and nothing else.\nThis second line is part of the same message;"
    let second = "Reply with \(c.nonce)-B and nothing else."
    #expect(try c.sbd.sb("send", s.id, first) == "pasted\n")
    #expect(try c.sbd.sb("send", s.id, second) == "queued\n")
    try c.waitFor(s.id, "the queued message's reply") { $0.lastReply?.contains("\(c.nonce)-B") == true }
    let prompts = try c.sbd.hooks(s.id, after: mark).filter { $0.kind == "UserPromptSubmit" }.map {
      $0.data["prompt"]?.string
    }
    #expect(prompts == [first, second])
  }

  @Test func reportsTheRunningTool() throws {
    let c = try ClaudeInstance(allow: ["Bash(./slow.sh:*)"])
    let command = "./slow.sh 4"
    let prompt = "Run exactly this command with the Bash tool: \(command)\nThen reply with \(c.nonce) and nothing else."
    let s = try c.sbd.new(prompt: prompt)
    let working = try c.waitFor(s.id, "the tool call") { $0.state == .working && $0.reason.contains("slow.sh") }
    #expect(working.reason.hasPrefix("`\(command)` ("))
    try c.waitFor(s.id, "the reply") { $0.lastReply?.contains(c.nonce) == true }
    let hooks = try c.sbd.hooks(s.id)
    let pre = try #require(hooks.first { $0.kind == "PreToolUse" && $0.data["tool_name"] == "Bash" })
    let post = try #require(hooks.first { $0.kind == "PostToolUse" && $0.data["tool_name"] == "Bash" })
    #expect(pre.data["tool_use_id"] != nil)
    #expect(post.data["tool_use_id"] == pre.data["tool_use_id"])
    #expect(pre.data["tool_input"]?["command"]?.string == command)
    #expect(post.t - pre.t >= 4000)
    try c.settle(s.id)
    try c.record("tool", s.id, after: try c.startupEnd(s.id), prompts: [prompt], commands: [command])
  }

  @Test func marksAPermissionPromptUntilTheTerminalAnswersIt() throws {
    let c = try ClaudeInstance(ask: ["Bash(touch:*)"])
    let command = "touch \(c.nonce).txt"
    let prompt = "Run exactly this command with the Bash tool: \(command)\nThen reply with DONE and nothing else."
    let s = try c.sbd.new(prompt: prompt)
    let asked = try c.waitFor(s.id, "the permission prompt") { $0.reason.hasPrefix("approve") }
    #expect(asked.state == .needsYou)
    #expect(asked.reason == "approve `\(command)`")
    // A PermissionRequest carries no tool_use_id, so sbd pairs it with its
    // PostToolUse by the tool's input.
    let request = try #require(try c.sbd.hooks(s.id).first { $0.kind == "PermissionRequest" })
    #expect(request.data["tool_use_id"] == nil)
    #expect(request.data["tool_input"]?["command"]?.string == command)
    try c.sbd.waitFor("the dialog") { try c.answer(s.id, .proceed) }
    let done = try c.waitFor(s.id, "the reply after the approval") { $0.lastReply != nil }
    #expect(!done.reason.hasPrefix("approve"))
    #expect(FileManager.default.fileExists(atPath: "\(c.sbd.work)/\(c.nonce).txt"))
    let post = try #require(try c.sbd.hooks(s.id).first { $0.kind == "PostToolUse" })
    #expect(post.data["tool_input"] == request.data["tool_input"])
    try c.settle(s.id)
    try c.record("permission", s.id, after: try c.startupEnd(s.id), prompts: [prompt], commands: [command])
  }

  @Test func marksAQuestionUntilTheTerminalAnswersIt() throws {
    let c = try ClaudeInstance()
    let prompt =
      "Use the AskUserQuestion tool to ask me the question \"Which fruit do you want?\", with the header Fruit and "
      + "the options apple, banana, and cherry. Then reply with the fruit I picked and nothing else."
    let s = try c.sbd.new(prompt: prompt)
    let asked = try c.waitFor(s.id, "the question") { $0.reason.hasPrefix("answer:") }
    #expect(asked.state == .needsYou)
    let pre = try #require(
      try c.sbd.hooks(s.id).first { $0.kind == "PreToolUse" && $0.data["tool_name"] == "AskUserQuestion" })
    let question = try #require(pre.data["tool_input"]?["questions"]?.array?.first)
    let text = try #require(question["question"]?.string)
    #expect(asked.reason == oneLine("answer: \(text)"))
    #expect(
      question["options"]?.array?.compactMap { $0["label"]?.string.map { $0.lowercased() } } == [
        "apple", "banana", "cherry",
      ])
    // The dialog's first line is the question's header chip.
    try c.sbd.waitFor("the question dialog") { try c.answer(s.id, .init(title: "^ ☐ ", item: "cherry")) }
    let done = try c.waitFor(s.id, "the reply after the answer") { $0.lastReply != nil }
    #expect(done.lastReply?.lowercased().contains("cherry") == true)
    #expect(!done.reason.hasPrefix("answer:"))
    // The result echoes the tool's `answers` input. answer-cards answers a
    // question by filling that input.
    let post = try #require(
      try c.sbd.hooks(s.id).first { $0.kind == "PostToolUse" && $0.data["tool_name"] == "AskUserQuestion" })
    #expect(post.data["tool_response"]?["answers"]?[text]?.string?.lowercased() == "cherry")
    try c.settle(s.id)
    try c.record("question", s.id, after: try c.startupEnd(s.id), prompts: [prompt])
  }

  @Test func stopsAnIdleSessionAndResumesTheConversation() throws {
    let c = try ClaudeInstance(idleStopSeconds: 3)
    let s = try c.sbd.new(prompt: "Remember the code \(c.nonce). Reply with OK and nothing else.")
    try c.waitFor(s.id, "the first reply") { $0.lastReply != nil }
    try c.waitFor(s.id, "the idle stop", timeout: 30) { !$0.live && $0.claudePid == nil }
    let stopped = try #require(try c.sbd.events(s.id).first { $0.kind == "stopped" })
    let end = try #require(try c.sbd.hooks(s.id).first { $0.kind == "SessionEnd" })
    #expect(end.id > stopped.id)
    #expect(end.data["reason"]?.string == "other")

    let question = "What was the code? Reply with it and nothing else."
    #expect(try c.sbd.sb("send", s.id, question) == "resumed\n")
    let resumed = try #require(try c.sbd.events(s.id).first { $0.kind == "resumed" })
    let start = try c.waitForHook(s.id, "SessionStart", after: resumed.id)
    #expect(start.data["source"]?.string == "resume")
    #expect(start.data["session_id"]?.string == s.claudeSessionId)
    // claude redraws the conversation from the transcript.
    try c.sbd.waitFor("the redrawn conversation", timeout: 5) {
      try c.screen(s.id).contains("Remember the code \(c.nonce)")
    }
    try c.waitFor(s.id, "the resumed reply") { $0.lastReply?.contains(c.nonce) == true }
    let submit = try c.waitForHook(s.id, "UserPromptSubmit", after: resumed.id)
    #expect(submit.data["prompt"]?.string == question)
    try c.record("sigterm", s.id, after: stopped.id, through: resumed.id)
    try c.record("resume", s.id, after: resumed.id, through: submit.id - 1)
  }

  @Test func followsTheConversationThatClearStarts() throws {
    let c = try ClaudeInstance()
    let s = try c.sbd.new(prompt: "Reply with OK and nothing else.")
    try c.waitFor(s.id, "the first reply") { $0.lastReply != nil }
    try c.settle(s.id)
    let mark = try c.lastEventId(s.id)
    #expect(try c.sbd.sb("send", s.id, "/clear") == "pasted\n")
    let start = try c.waitForHook(s.id, "SessionStart", after: mark)
    #expect(start.data["source"]?.string == "clear")
    let next = try #require(start.data["session_id"]?.string)
    #expect(next != s.claudeSessionId)
    let end = try #require(try c.sbd.hooks(s.id, after: mark).first { $0.kind == "SessionEnd" })
    #expect(end.data["reason"]?.string == "clear")
    #expect(end.data["session_id"]?.string == s.claudeSessionId)
    try c.waitFor(s.id, "the new conversation") { $0.claudeSessionId == next }
    try c.settle(s.id)
    try c.record("clear", s.id, after: mark)

    try c.sbd.sb("stop", s.id)
    try c.waitFor(s.id, "the stop") { $0.claudePid == nil }
    let resumed = try c.lastEventId(s.id)
    try c.sbd.sb("send", s.id, "Reply with \(c.nonce) and nothing else.")
    let again = try c.waitForHook(s.id, "SessionStart", after: resumed)
    #expect(again.data["session_id"]?.string == next)
    try c.waitFor(s.id, "the reply in the new conversation") { $0.lastReply?.contains(c.nonce) == true }
  }

  @Test func keepsASessionLiveWhileItsBackgroundJobRuns() throws {
    let c = try ClaudeInstance(idleStopSeconds: 2, allow: ["Bash(./slow.sh:*)"])
    let command = "./slow.sh 10"
    let prompt =
      "Run exactly this command with the Bash tool, with run_in_background set to true: \(command)\n"
      + "Don't wait for it. End your turn at once, replying with STARTED and nothing else."
    let s = try c.sbd.new(prompt: prompt)
    let pre = try c.waitForHook(s.id, "PreToolUse") { $0.data["tool_input"]?["run_in_background"] == true }
    let stop = try c.waitForHook(s.id, "Stop", after: pre.id)
    #expect(stop.data["background_tasks"]?.array?.first?["status"] == "running")
    // The stop rule finds the job as a child of claude that leads its own
    // process group.
    sleep(5)
    #expect(try c.sbd.get(s.id).live)
    let notice = try c.waitForHook(s.id, "UserPromptSubmit", after: stop.id, timeout: 30)
    let text = notice.data["prompt"]?.string ?? ""
    #expect(text.hasPrefix("<task-notification>"))
    #expect(Attention.isSubagentResult(text))
    try c.waitFor(s.id, "the idle stop after the job", timeout: 30) { !$0.live }
    let stopped = try #require(try c.sbd.events(s.id).first { $0.kind == "stopped" })
    try #require(stopped.id > notice.id)
    try c.record(
      "background-job", s.id, after: try c.startupEnd(s.id), through: stopped.id, prompts: [prompt], commands: [command]
    )
  }

  /// The subagent's tool call outlasts the launch turn, so the hooks come in
  /// the same order on every run.
  @Test func reportsABackgroundSubagent() throws {
    let c = try ClaudeInstance(allow: ["Bash(./slow.sh:*)"])
    let command = "./slow.sh 3"
    let prompt =
      "Use the Agent tool with subagent_type general-purpose to start one subagent. Its task: run exactly this "
      + "command with the Bash tool: \(command)\nThen reply with \(c.nonce) and nothing else. "
      + "Don't do anything else yourself."
    let s = try c.sbd.new(prompt: prompt)
    let start = try c.waitForHook(s.id, "SubagentStart")
    let agent = try #require(start.data["agent_id"]?.string)
    // A subagent's tool calls fire the session's hooks with its agent_id.
    let call = try c.waitForHook(s.id, "PreToolUse", after: start.id) { $0.data["tool_name"] == "Bash" }
    #expect(call.data["agent_id"]?.string == agent)
    let result = try c.waitForHook(s.id, "UserPromptSubmit", after: start.id) {
      Attention.isSubagentResult($0.data["prompt"]?.string ?? "")
    }
    #expect(result.data["prompt"]?.string?.contains(agent) == true)
    try c.waitForHook(s.id, "SubagentStop", after: start.id) { $0.data["agent_id"]?.string == agent }
    try c.waitForHook(s.id, "Stop", after: result.id)
    try c.settle(s.id)
    try c.record("subagent", s.id, after: try c.startupEnd(s.id), prompts: [prompt], commands: [command])
  }

  @Test func sendsNoHookAfterEscapeInterruptsATurn() throws {
    let c = try ClaudeInstance(allow: ["Bash(./slow.sh:*)"])
    let command = "./slow.sh 60"
    let prompt = "Run exactly this command with the Bash tool: \(command)\nThen reply with DONE and nothing else."
    let s = try c.sbd.new(prompt: prompt)
    try c.waitFor(s.id, "the tool call") { $0.state == .working && $0.reason.contains("slow.sh") }
    let mark = try c.lastEventId(s.id)
    try c.press(s.id, "Escape")
    // Phase 0 saw idle_prompt 60 s after a Stop. After Escape, no Stop,
    // PostToolUseFailure, or idle_prompt comes.
    sleep(70)
    #expect(try c.sbd.hooks(s.id, after: mark).map(\.kind) == [])
    let agents = JSON.parse(try runCommand(c.claude, ["agents", "--json"]).stdout)?.array ?? []
    let row = agents.first { $0["sessionId"]?.string == s.claudeSessionId }
    #expect(row?["status"] == "idle")
    let state = try c.sbd.get(s.id).state
    withKnownIssue("sbd ends a turn only on a hook. The fix reads the status from `claude agents --json`.") {
      #expect(state != .working)
    }
    try c.record("interrupt", s.id, after: try c.startupEnd(s.id), prompts: [prompt], commands: [command])
  }
}
