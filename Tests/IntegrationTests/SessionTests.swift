import Foundation
import SwitchboardCore
import Testing

@Suite(.timeLimit(.minutes(2))) struct SessionTests {
  @Test func startsClaudeWithTheFirstPromptAndTracksTheTurn() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello there")
    let done = try sbd.waitFor(s.id, "the first turn's reply") { $0.lastReply == "Done: hello there" }
    #expect(done.live)
    #expect(done.state == .needsYou)
    #expect(done.reason == "read its last reply and decide what's next")
    #expect(
      sbd.stubArgs().first == "--session-id \(s.claudeSessionId) --settings \(sbd.home.claudeSettings) -- hello there")
    try sbd.waitFor(s.id, "claude's pid") { $0.claudePid != nil }
    #expect(try sbd.sb("screen", s.id).contains("⏺ Done: hello there"))
  }

  @Test func sortsRepliesIntoQuestionsAndOffers() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply != nil }
    try sbd.sb("send", s.id, "ask which db")
    let asked = try sbd.waitFor(s.id, "the question") { $0.lastReply?.hasPrefix("Which database") == true }
    #expect(asked.state == .needsYou)
    #expect(asked.reason == "answer: Which database should I use, Postgres or SQLite?")
    try sbd.sb("send", s.id, "offer a parser")
    let offered = try sbd.waitFor(s.id, "the offer") { $0.state == .canContinue }
    #expect(offered.reason == "offered: Want me to run the tests?")
  }

  @Test func showsTheRunningTool() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "slow 3")
    let working = try sbd.waitFor(s.id, "the tool call") { $0.state == .working && $0.reason.contains("sleep") }
    #expect(working.reason.hasPrefix("`sleep 3` ("))
    try sbd.waitFor(s.id, "the end of the turn", timeout: 20) { $0.lastReply == "Slept 3 s." }
  }

  @Test func queuesAMessageThatArrivesDuringATurn() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "slow 2")
    try sbd.waitFor(s.id, "the turn") { $0.state == .working }
    #expect(try sbd.sb("send", s.id, "after the slow one") == "queued\n")
    try sbd.waitFor(s.id, "the queued message's reply", timeout: 20) { $0.lastReply == "Done: after the slow one" }
  }

  @Test func sendsTwoMessagesInARowAsTwoTurns() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.waitFor("the prompt to settle") { (try sbd.events(s.id).last.map { nowMs() - $0.t > 1600 }) ?? false }
    #expect(try sbd.sb("send", s.id, "lag first --model opus") == "pasted\n")
    #expect(try sbd.sb("send", s.id, "second") == "queued\n")
    try sbd.waitFor(s.id, "the second reply", timeout: 20) { $0.lastReply == "Done: second" }
    let prompts = try sbd.events(s.id).filter { $0.kind == "UserPromptSubmit" }.compactMap { $0.data["prompt"]?.string }
    #expect(prompts == ["hello", "lag first --model opus", "second"])
  }

  @Test func deliversAQueuedMessageAfterATurnThatEndsWithoutAStop() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.sb("send", s.id, "interrupt it")
    try sbd.waitFor(s.id, "the interrupted turn") { $0.state == .working }
    #expect(try sbd.sb("send", s.id, "after the interrupt") == "queued\n")
    // Claude Code sends no hook after Escape, so no event tells sbd that the turn ended.
    withKnownIssue("sbd ends a turn only on a hook. The fix reads the status from `claude agents --json`.") {
      try sbd.waitFor(s.id, "the queued message's reply", timeout: 5) { $0.lastReply == "Done: after the interrupt" }
    }
  }

  @Test func endsATurnThatFailsWithoutAStop() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "fail now")
    try sbd.waitFor("the failed turn") { (try? sbd.events(s.id).last?.kind) == "StopFailure" }
    #expect(try sbd.get(s.id).state != .working)
  }

  @Test func stopsAnIdleSessionAndResumesItWithTheNextMessage() throws {
    let sbd = try Instance(idleStopSeconds: 2)
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.waitFor(s.id, "the idle stop", timeout: 15) { !$0.live }
    // A message that starts with a dash reaches claude as the prompt.
    #expect(try sbd.sb("send", s.id, "- fix A") == "resumed\n")
    try sbd.waitFor(s.id, "the resumed turn") { $0.lastReply == "Done: - fix A" }
    #expect(sbd.stubArgs().last == "--resume \(s.claudeSessionId) --settings \(sbd.home.claudeSettings) -- - fix A")
  }

  @Test func resumesTheConversationThatClearStarted() throws {
    let sbd = try Instance(idleStopSeconds: 2)
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    let next = UUID().uuidString.lowercased()
    try sbd.sb("send", s.id, "clear \(next)")
    try sbd.waitFor(s.id, "the new conversation") { $0.claudeSessionId == next }
    try sbd.waitFor(s.id, "the idle stop", timeout: 15) { !$0.live }
    try sbd.sb("send", s.id, "after the clear")
    try sbd.waitFor(s.id, "the resumed turn") { $0.lastReply == "Done: after the clear" }
    #expect(sbd.stubArgs().last?.hasPrefix("--resume \(next) ") == true)
  }

  @Test func keepsAQueuedMessageAcrossARestartOfSbd() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "slow 4")
    try sbd.waitFor(s.id, "the turn") { $0.state == .working }
    #expect(try sbd.sb("send", s.id, "kept across the restart") == "queued\n")
    sbd.stopSbd()
    try sbd.startSbd()
    try sbd.waitFor(s.id, "the queued message's reply", timeout: 20) { $0.lastReply == "Done: kept across the restart" }
  }

  @Test func pastesTextThatTmuxWouldChange() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    // tmux strips a trailing semicolon from a command argument.
    try sbd.sb("send", s.id, "fix the bug;")
    try sbd.waitFor(s.id, "the semicolon") { $0.lastReply == "Done: fix the bug;" }
    // In copy mode, Enter goes to tmux instead of claude.
    let t = try sbd.client.terminals(s.id)
    #expect(try runCommand(t.tmux, ["-S", t.socket, "copy-mode", "-t", "=\(t.claude):"]).status == 0)
    try sbd.sb("send", s.id, "after copy mode")
    try sbd.waitFor(s.id, "the reply after copy mode") { $0.lastReply == "Done: after copy mode" }
  }

  @Test func keepsASessionRunningWhileATerminalIsAttached() throws {
    let sbd = try Instance(idleStopSeconds: 2)
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    let detach = try sbd.attach(s.id)
    try sbd.waitFor(s.id, "the attached flag") { $0.attached }
    sleep(4)
    #expect(try sbd.get(s.id).live)
    detach()
    try sbd.waitFor(s.id, "the idle stop after detaching", timeout: 15) { !$0.live }
  }

  @Test func keepsSessionsAcrossARestartOfSbd() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "ask it")
    let asked = try sbd.waitFor(s.id, "the question") { $0.state == .needsYou && $0.reason.hasPrefix("answer:") }
    sbd.stopSbd()
    try sbd.startSbd()
    let after = try sbd.waitFor(s.id, "the session after the restart") { $0.live }
    #expect(after.reason == "answer: Which database should I use, Postgres or SQLite?")
    #expect(after.since == asked.since)
    try sbd.sb("send", s.id, "offer it")
    try sbd.waitFor(s.id, "a turn after the restart") { $0.state == .canContinue }
  }

  @Test func noticesWhenClaudeExitsWithoutAHook() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")
    let live = try sbd.waitFor(s.id, "claude") { $0.claudePid != nil && $0.lastReply != nil }
    kill(pid_t(live.claudePid!), SIGKILL)
    try sbd.waitFor(s.id, "the exit", timeout: 15) { !$0.live }
  }

  @Test func marksDoneAndWaiting() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply != nil }
    try sbd.sb("wait", s.id, "CI", "on", "#12")
    #expect(try sbd.get(s.id).state == .waiting)
    #expect(try sbd.get(s.id).reason == "CI on #12")
    try sbd.sb("wait", s.id, "--clear")
    try sbd.sb("done", s.id)
    #expect(try sbd.get(s.id).state == .done)
    let list = try JSONCoding.decode([SessionSummary].self, from: try sbd.sb("ls", "--json"))
    #expect(list.map(\.id) == [s.id])
  }

  @Test func removesASessionAndItsPanes() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")
    let terminals = try sbd.client.terminals(s.id)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply != nil }
    try sbd.sb("rm", s.id)
    #expect(try sbd.client.sessions().isEmpty)
    #expect(
      try runCommand(terminals.tmux, ["-S", terminals.socket, "has-session", "-t", "=\(terminals.claude)"]).status != 0)
  }

  @Test func createsAWorktreeForANewBranch() throws {
    let sbd = try Instance()
    let repo = try Repos.create("\(sbd.home.path)/repo")
    let s = try sbd.client.call(
      "new", ["path": .string(repo), "branch": "haacked/feature", "prompt": "hello"], as: SessionSummary.self)
    #expect(s.cwd == "\(sbd.home.path)/worktrees/repo/haacked/feature")
    #expect(s.branch == "haacked/feature")
    #expect(try sbd.git(s.cwd, "branch", "--show-current") == "haacked/feature")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    // A folder at the worktree's path that isn't a worktree of this repo is refused.
    try FileManager.default.createDirectory(
      atPath: "\(sbd.home.path)/worktrees/repo/haacked/other", withIntermediateDirectories: true)
    #expect(throws: APIError.self) {
      try sbd.client.call("new", ["path": .string(repo), "branch": "haacked/other"])
    }
  }
}

@Suite struct HookTests {
  @Test func hookIsSilentWhenSbdIsDown() throws {
    var env = ProcessInfo.processInfo.environment
    env["SB_HOME"] = "/tmp/sb-no-such-home"
    env["SB_SESSION_ID"] = "s1"
    let start = Date()
    let r = try runCommand("\(Instance.bin)/sb", ["hook"], env: env, input: Data(#"{"hook_event_name":"Stop"}"#.utf8))
    #expect(r.status == 0)
    #expect(r.stdout.isEmpty)
    #expect(r.stderr.isEmpty)
    #expect(Date().timeIntervalSince(start) < 2)
  }
}
