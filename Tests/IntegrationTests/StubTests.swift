import Foundation
import SwitchboardCore
import Testing

/// The stub plays the payloads that the real claude tier recorded, so sbd
/// sees the same events from the stub as from claude.
@Suite(.blocking(timeLimit: .seconds(120))) struct StubTests {
  /// Normalizes the stub's payloads after the event id `after`, through the
  /// event id `through`, as the real tier normalizes its own, and compares
  /// them with the step's recording.
  func expectRecorded(
    _ step: String, _ sbd: Instance, _ id: String, after: Int64, through: Int64 = .max, prompts: [String] = [],
    commands: [String] = [], sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    let payloads = try sbd.stepPayloads(id, after: after, through: through)
    // The stub leaves only the ids that claude assigns as placeholders.
    let ids: Set = ["prompt_id", "tool_use_id", "agent_id", "task_id"]
    let unfilled = payloads.flatMap { $0.text.matches(of: #/\{\{([a-z_]+?)(_[0-9]+)?\}\}/#).map { String($0.1) } }
      .filter { !ids.contains($0) }
    #expect(unfilled.isEmpty, "the stub's \(step) step left \(unfilled) unfilled", sourceLocation: sourceLocation)
    let context = Recording.Context(
      cwd: [sbd.work], home: NSHomeDirectory(), nonce: "", prompts: prompts, commands: commands)
    let played = Recording.normalize(payloads, context).map(\.text)
    let recorded = try Recording.read("\(Recording.folder)/\(step).jsonl").map(\.text)
    #expect(played == recorded, "the stub's \(step) step", sourceLocation: sourceLocation)
  }

  @Test func playsTheRecordedSteps() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    let startupEnd = try sbd.startupEnd(s.id)
    try expectRecorded("startup", sbd, s.id, after: 0, through: startupEnd)
    try expectRecorded("turn", sbd, s.id, after: startupEnd, prompts: ["hello"])

    var mark = try sbd.lastEventId(s.id)
    try sbd.sb("send", s.id, "slow 1")
    try sbd.waitFor(s.id, "the tool call's reply") { $0.lastReply == "Slept 1 s." }
    try expectRecorded("tool", sbd, s.id, after: mark, prompts: ["slow 1"], commands: ["sleep 1"])

    mark = try sbd.lastEventId(s.id)
    let next = UUID().uuidString.lowercased()
    try sbd.sb("send", s.id, "clear \(next)")
    try sbd.waitFor(s.id, "the new conversation") { $0.claudeSessionId == next }
    try expectRecorded("clear", sbd, s.id, after: mark)

    // The session stops only after the clock passes the 600 s idle wait.
    try sbd.advanceClock(600_000)
    try sbd.waitFor(s.id, "the idle stop") { !$0.live }
    let stopped = try #require(try sbd.events(s.id).last { $0.kind == "stopped" })
    try sbd.sb("send", s.id, "again")
    try sbd.waitFor(s.id, "the resumed reply") { $0.lastReply == "Done: again" }
    let resumed = try #require(try sbd.events(s.id).last { $0.kind == "resumed" })
    let again = try #require(try sbd.events(s.id).last { $0.kind == "UserPromptSubmit" })
    try expectRecorded("sigterm", sbd, s.id, after: stopped.id, through: resumed.id)
    try expectRecorded("resume", sbd, s.id, after: resumed.id, through: again.id - 1)
  }

  /// An interrupted turn never ends, so this runs in a session of its own.
  @Test func playsTheRecordedBackgroundJobAndInterrupt() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "background 1")
    try sbd.waitFor("the job's report", timeout: 30) { try sbd.events(s.id).filter { $0.kind == "Stop" }.count == 2 }
    try expectRecorded(
      "background-job", sbd, s.id, after: try sbd.startupEnd(s.id), prompts: ["background 1"], commands: ["sleep 1"])

    let mark = try sbd.lastEventId(s.id)
    try sbd.sb("send", s.id, "interrupt it")
    try sbd.waitFor(s.id, "the interrupted tool call") { $0.reason.hasPrefix("`sleep 100`") }
    try expectRecorded("interrupt", sbd, s.id, after: mark, prompts: ["interrupt it"], commands: ["sleep 100"])
  }

  /// SIGTERM ends a tool call at once, as it ends one of claude's, and the stub plays its sigterm step.
  @Test func sigtermEndsASlowToolCallAtOnce() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "slow 30")
    let working = try sbd.waitFor(s.id, "the tool call") { $0.state == .working && $0.claudePid != nil }
    let stub = try #require(working.claudePid)
    // The stub starts the sleep only after the PreToolUse hook returns. A SIGTERM before then ends the stub at once
    // even if the sleep runs in the foreground.
    let sleepPid = try sbd.waitFor(
      "the tool call's sleep",
      fetch: {
        let found = try runCommand("/usr/bin/pgrep", ["-P", "\(stub)", "-f", "^sleep 30$"]).stdout
        return pid_t(found.split(separator: "\n").first ?? "")
      }, until: { _ in true })
    let mark = try sbd.lastEventId(s.id)

    kill(pid_t(stub), SIGTERM)

    try sbd.waitFor("the stub and its sleep to exit before the 30 s tool call ends", timeout: 5) {
      try kill(sleepPid, 0) != 0
        && runCommand("/bin/ps", ["-axo", "command="]).stdout.split(separator: "\n")
          .allSatisfy { !($0.contains("claude-stub") && $0.contains(working.claudeSessionId)) }
    }
    try sbd.waitFor("the SessionEnd hook") {
      try sbd.events(s.id).contains { $0.id > mark && $0.kind == "SessionEnd" }
    }
  }

  /// A claude that dies mid-turn sends no more hooks, so no process that runs
  /// the stub may outlive it.
  @Test func aKilledStubSendsNoMoreHooks() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "slow 20")
    let working = try sbd.waitFor(s.id, "the tool call") { $0.state == .working && $0.claudePid != nil }
    try sbd.waitFor("the PreToolUse hook") { try sbd.events(s.id).contains { $0.kind == "PreToolUse" } }
    kill(pid_t(working.claudePid!), SIGKILL)
    try sbd.waitFor("the stub's processes to exit") {
      try runCommand("/bin/ps", ["-axo", "command="]).stdout.split(separator: "\n")
        .allSatisfy { !($0.contains("claude-stub") && $0.contains(working.claudeSessionId)) }
    }
  }
}
