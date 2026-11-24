import Foundation
import SwitchboardCore
import Testing

/// The UserPromptSubmit block of D17 for a work skill typed in a conversation named `conversation`.
private func promptReason(_ skill: String, session: String) -> String {
  "Switchboard blocked /\(skill) in this Manager conversation. /\(skill) is a work skill, and a Manager rereads "
    + "everything it loads on every later turn. Start a session for it instead: send it again from the "
    + "conversation's Message Claude field in Switchboard (⇧⌘E) and pick Spawn a session with this, or run "
    + "sb spawn --repo <owner/name> --branch <branch> --prompt \"/\(skill) …\". To run it here once, pick Run here "
    + "anyway, or run sb send \(session) --run-here \"/\(skill) …\" in a terminal. sb manager skills lists the "
    + "labels."
}

/// The PreToolUse deny of D17 for a work skill.
private func toolReason(_ skill: String) -> String {
  "Switchboard denied the \(skill) skill. It is a work skill, and this Manager conversation rereads everything "
    + "it loads on every later turn. Start a session for the work instead, with the spawn tool or sb new <repo> "
    + "--branch <branch> --prompt \"/\(skill) <args>\", and follow it with a wait. Don't load the skill's text "
    + "another way, such as by reading its SKILL.md."
}

private func write(_ text: String, to path: String) throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try text.write(toFile: path, atomically: true, encoding: .utf8)
}

/// A Manager conversation's or the operator's prompt that starts with a work skill's command is blocked in the
/// UserPromptSubmit hook, and a Skill tool call of one is denied in the PreToolUse hook. The stub skips the turn of
/// a blocked prompt, as Claude Code does: no transcript line, no reply, and no Stop.
@Suite(.blocking(timeLimit: .seconds(180))) struct ManagerSkillHookTests: ManagerSkillSuite {
  // MARK: Prompt block

  @Test func slashGoInAManagerIsBlockedWithTheReasonOfD17() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)

    try sbd.sb("send", c.id, "/go x")

    let blocked = try waitForEvents(sbd, c.id, "skill_blocked")
    #expect(blocked.count == 1)
    #expect(blocked.first?.data["skill"]?.string == "go")
    #expect(blocked.first?.data["via"]?.string == "prompt")
    #expect(blocked.first?.data["by"]?.string == "haiku")
    let answer = try sbd.waitFor("the stub's block", fetch: { blocks(sbd, c).first }, until: { _ in true })
    #expect(answer["reason"]?.string == promptReason("go", session: c.id))
  }

  /// The block's reason goes to the user, so neither the skill's file nor the classifier's reason may be in it.
  @Test func theBlockHoldsNoSkillTextAndNoClassifierReason() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)

    try sbd.sb("send", c.id, "/go x")

    let answer = try sbd.waitFor("the stub's block", fetch: { blocks(sbd, c).first }, until: { _ in true })
    let reason = try #require(answer["reason"]?.string)
    #expect(!reason.contains("Run the pipeline."), "\(reason)")
    #expect(!reason.contains("The go skill."), "\(reason)")
    #expect(!reason.contains("It runs a pipeline."), "\(reason)")
  }

  /// The next prompt's reply shows that the stub finished with the blocked one.
  @Test func aBlockedPromptGetsNoReplyAndNoTranscriptLine() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)
    try sbd.sb("send", c.id, "/go x")
    try waitForEvents(sbd, c.id, "skill_blocked")

    try prompt(sbd, c, "after")

    #expect(!sbd.transcriptContains(c, "/go x"))
    #expect(!sbd.transcriptContains(c, "Done: /go x"))
  }

  /// Claude Code sends no Stop after a block, so the `skill_blocked` event ends the turn.
  @Test func aBlockedPromptLeavesWorkingWithoutAStop() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)
    let stops = try sbd.events(c.id, kind: "Stop").count

    try sbd.sb("send", c.id, "/go x")

    try waitForEvents(sbd, c.id, "skill_blocked")
    try stays("the Manager left Working") { try sbd.get(c.id).state != .working }
    #expect(try sbd.events(c.id, kind: "Stop").count == stops)
  }

  /// A blocked first prompt doesn't name the conversation and records no digest. The next prompt that runs does.
  @Test func aBlockedPromptLeavesTheNameAndTheDigestForTheNextPrompt() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "go")
    let c = try newConversation(sbd)
    try waitForLabel(sbd, "go", "work")
    let digests = try sbd.events(c.id, kind: "digest").count

    try sbd.sb("send", c.id, "/go x")

    try waitForEvents(sbd, c.id, "skill_blocked")
    #expect(try sbd.get(c.id).name == c.name)
    #expect(try sbd.events(c.id, kind: "digest").count == digests)
    try prompt(sbd, c, "Fix the cache")
    #expect(try sbd.get(c.id).name == "Fix the cache")
  }

  /// A child flips while the Manager waits. A blocked `/go` must not mark the child as heard, so the next prompt
  /// that runs still gets the child's line.
  @Test func theDigestSurvivesABlock() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)
    let kid = try decode(
      SessionSummary.self,
      sbd.sb(
        "new", "--json", "--name", "kid", "--prompt", "one", sbd.work,
        env: ["SB_SESSION_ID": c.id, "CLAUDECODE": "1"]))
    try sbd.waitFor(kid.id, "the kid's reply") { $0.lastReply == "Done: one" && $0.state == .needsYou }
    for text in ["two", "three"] {
      try sbd.sb("send", kid.id, text)
      try sbd.waitFor(kid.id, "the reply to \(text)") { $0.lastReply == "Done: \(text)" && $0.state == .needsYou }
    }
    try sbd.sb("send", c.id, "/go x")
    try waitForEvents(sbd, c.id, "skill_blocked")
    let before = contexts(sbd, c).count

    try prompt(sbd, c, "what changed")

    let given = contexts(sbd, c).dropFirst(before)
    let line = "- kid (\(kid.id)): needs you"
    #expect(given.contains { $0.contains(line) }, "\(Array(given))")
  }

  /// The additionalContext of each hook answer that the conversation's claude got, oldest first.
  func contexts(_ sbd: Instance, _ s: SessionSummary) -> [String] {
    sbd.hookOutputs(s.claudeSessionId).compactMap { $0["hookSpecificOutput"]?["additionalContext"]?.string }
  }

  /// No Stop follows a block, so the end of the turn is what delivers a message that waited behind it. sbd also
  /// retries 10 s after the blocked prompt's paste, so the queued message's paste has to come sooner than that on
  /// sbd's clock.
  @Test func aMessageQueuedBehindABlockedPromptIsDelivered() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)
    sbd.hold("hold")
    try sbd.sb("send", c.id, "/go x")
    try sbd.waitFor("the stub to read /go x") { sbd.stubInputCount("/go x") >= 1 }
    let queued = try sbd.sb("send", c.id, "after")
    try #require(queued.contains("queued"), "\(queued)")

    sbd.hold("report")

    try waitForEvents(sbd, c.id, "skill_blocked")
    try sbd.waitFor(c.id, "the queued message's reply", timeout: 30) { $0.lastReply == "Done: after" }
    let pastes = try sbd.events(c.id, kind: "pasting")
    let blocked = try #require(pastes.first { $0.data["text"]?.string == "/go x" })
    let queuedPaste = try #require(pastes.first { $0.data["text"]?.string == "after" })
    #expect(queuedPaste.t - blocked.t < 10_000, "the queued message waited \(queuedPaste.t - blocked.t) ms")
  }

  // MARK: Scope

  enum Target: CaseIterable {
    case manager, operatorSession, work, chat

    var blocks: Bool { self == .manager || self == .operatorSession }
  }

  /// Only a Manager conversation and the operator are gated. A work session and a group chat get the skill.
  @Test(arguments: Target.allCases) func slashGoIsBlockedOnlyInAManagerConversationAndTheOperator(_ target: Target)
    throws
  {
    let sbd = try instance()
    let c = try workGoConversation(sbd)
    let s: SessionSummary
    switch target {
    case .manager:
      s = c
    case .operatorSession:
      let op = try decode(SessionSummary.self, sbd.sb("operator", "--json"))
      s = try sbd.waitFor(op.id, "the operator's claude") { $0.live }
    case .work:
      let w = try sbd.new(prompt: "hello")
      s = try sbd.waitFor(w.id, "the work session's reply") { $0.lastReply == "Done: hello" }
    case .chat:
      _ = try sbd.sb("group", "add", "--json", "Flags")
      let chat = try decode(SessionSummary.self, sbd.sb("chat", "Flags", "--json"))
      s = try sbd.waitFor(chat.id, "the chat's claude") { $0.live }
    }

    try sbd.sb("send", s.id, "/go x")

    if target.blocks {
      let blocked = try waitForEvents(sbd, s.id, "skill_blocked")
      #expect(blocked.first?.data["via"]?.string == "prompt")
      try prompt(sbd, s, "after")
      #expect(!sbd.transcriptContains(s, "Done: /go x"))
    } else {
      try sbd.waitFor(s.id, "the reply to /go x", timeout: 30) { $0.lastReply == "Done: /go x" }
      #expect(try sbd.events(s.id, kind: "skill_blocked").isEmpty)
      #expect(try sbd.events(s.id, kind: "skill_unchecked").isEmpty)
      #expect(blocks(sbd, s).isEmpty)
    }
  }

  // MARK: Fail-open

  @Test func aSafeSkillAndABuiltInAreNotBlocked() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "notes", "Append to the notes file. LABEL-SAFE")
    let c = try workGoConversation(sbd)
    try waitForLabel(sbd, "notes", "safe")

    try prompt(sbd, c, "/notes x")
    try prompt(sbd, c, "/clear")

    #expect(try sbd.events(c.id, kind: "skill_blocked").isEmpty)
    #expect(try sbd.events(c.id, kind: "skill_unchecked").isEmpty)
    #expect(blocks(sbd, c).isEmpty)
  }

  /// A skill whose run is still going has no label yet. It runs, and sbd records one `skill_unchecked` for it.
  @Test func anUnlabeledSkillRunsAndRecordsOneUncheckedAcrossTwoPrompts() throws {
    let sbd = try instance(config: ["managerSkills": ["timeoutSeconds": 120]])
    let c = try workGoConversation(sbd)
    try writeSkill(sbd.account("A"), "pending", "SLOW-SKILL")
    try sbd.sb("manager", "skills", "relabel", "pending")
    try sbd.waitFor("the pending skill's run") { calls(sbd, "pending") == 1 }

    try prompt(sbd, c, "/pending a")
    try prompt(sbd, c, "/pending b")

    let unchecked = try sbd.events(c.id, kind: "skill_unchecked")
    #expect(unchecked.count == 1, "\(unchecked.map(\.data.text))")
    #expect(unchecked.first?.data["skill"]?.string == "pending")
    #expect(unchecked.first?.data["why"]?.string == "unlabeled")
    #expect(try sbd.events(c.id, kind: "skill_blocked").isEmpty)
  }

  /// A failed claude call holds back the account's other runs, so `flaky` fails only after `go` has its label.
  @Test func aFailedSkillRunsAndRecordsOneUncheckedWithWhyFailed() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)
    try writeSkill(sbd.account("A"), "flaky", "FAIL-SKILL")
    try sbd.sb("manager", "skills", "relabel", "flaky")
    try waitForError(sbd, "flaky")

    try prompt(sbd, c, "/flaky a")
    try prompt(sbd, c, "/flaky b")

    let unchecked = try sbd.events(c.id, kind: "skill_unchecked")
    #expect(unchecked.count == 1, "\(unchecked.map(\.data.text))")
    #expect(unchecked.first?.data["skill"]?.string == "flaky")
    #expect(unchecked.first?.data["why"]?.string == "failed")
    #expect(unchecked.first?.data["error"]?.string?.isEmpty == false)
  }

  /// The gate is dictionary lookups, so the hook answers at once while `skillJobs` runs a classification that
  /// hangs.
  @Test func theHookAnswersWhileAClassificationHangs() throws {
    let sbd = try instance(config: ["managerSkills": ["timeoutSeconds": 120]])
    let c = try workGoConversation(sbd)
    try writeSkill(sbd.account("A"), "a-slow", "SLOW-SKILL")
    try sbd.sb("manager", "skills", "relabel", "a-slow")
    try sbd.waitFor("the slow run") { calls(sbd, "a-slow") == 1 }

    let started = Date()
    let go = try hookPrompt(sbd, c, "/go x")
    let slow = try hookPrompt(sbd, c, "/a-slow")
    let seconds = Date().timeIntervalSince(started)

    #expect(isBlock(go), "\(go.text)")
    #expect(!isBlock(slow), "\(slow.text)")
    #expect(seconds < 2 * Instance.timeoutScale, "the two hooks took \(seconds) s")
  }

  // MARK: Tool deny

  @Test func theSkillToolIsDeniedWithTheReasonOfD17() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)

    try sbd.sb("send", c.id, "skill go")

    let replied = try sbd.waitFor(c.id, "the denied call's reply", timeout: 30) {
      $0.lastReply?.hasPrefix("Denied:") == true
    }
    #expect(replied.lastReply == "Denied: \(toolReason("go"))")
    let denied = try #require(denials(sbd, c).first)
    #expect(denied["hookSpecificOutput"]?["hookEventName"]?.string == "PreToolUse")
    #expect(denied["hookSpecificOutput"]?["permissionDecisionReason"]?.string == toolReason("go"))
    let blocked = try sbd.events(c.id, kind: "skill_blocked")
    #expect(blocked.count == 1)
    #expect(blocked.first?.data["via"]?.string == "tool")
    #expect(blocked.first?.data["by"]?.string == "haiku")
  }

  @Test func aSubagentsSkillCallIsDenied() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)

    try sbd.sb("send", c.id, "subskill go")

    try sbd.waitFor(c.id, "the denied call's reply", timeout: 30) { $0.lastReply?.hasPrefix("Denied:") == true }
    #expect(try sbd.events(c.id, kind: "skill_blocked").first?.data["via"]?.string == "tool")
  }

  @Test func aSafeSkillCallIsAllowed() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "notes", "Append to the notes file. LABEL-SAFE")
    let c = try workGoConversation(sbd)
    try waitForLabel(sbd, "notes", "safe")

    try sbd.sb("send", c.id, "skill notes")

    try sbd.waitFor(c.id, "the call's reply", timeout: 30) { $0.lastReply == "Skill notes" }
    #expect(denials(sbd, c).isEmpty)
  }

  @Test func theLegacySlashCommandToolIsDenied() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)

    let answer = try hook(
      sbd, c,
      [
        "hook_event_name": "PreToolUse", "tool_name": "SlashCommand", "tool_input": ["command": "/go x"],
        "tool_use_id": "t1",
      ])

    #expect(isDeny(answer), "\(answer.text)")
    #expect(answer["hookSpecificOutput"]?["permissionDecisionReason"]?.string == toolReason("go"))
  }

  @Test func aSkillCallInAWorkSessionIsNotDenied() throws {
    let sbd = try instance()
    try workGoConversation(sbd)
    let w = try sbd.new(prompt: "hello")
    try sbd.waitFor(w.id, "the work session's reply") { $0.lastReply == "Done: hello" }

    try sbd.sb("send", w.id, "skill go")

    try sbd.waitFor(w.id, "the call's reply", timeout: 30) { $0.lastReply == "Skill go" }
    #expect(try sbd.events(w.id, kind: "skill_blocked").isEmpty)
  }

  // MARK: Refresh

  /// A manager-kind prompt scans the account again when its last scan is at least 60 s old, and not sooner.
  @Test func aPromptScansTheSkillsAgainAfterAMinute() throws {
    let sbd = try instance(idleStopSeconds: 3600)
    let c = try workGoConversation(sbd)
    try writeSkill(sbd.account("A"), "late")

    try hookPrompt(sbd, c, "soon")
    try stays("late stays out of the index") { row("late", try skills(sbd)) == nil }
    try sbd.advanceClock(61_000)
    try hookPrompt(sbd, c, "a minute later")

    try waitForLabel(sbd, "late", "work")
  }

  @Test func aSkillCallScansTheSkillsAgainAfterAMinute() throws {
    let sbd = try instance(idleStopSeconds: 3600)
    let c = try workGoConversation(sbd)
    try writeSkill(sbd.account("A"), "late")

    try hookSkillCall(sbd, c, "notes")
    try stays("late stays out of the index") { row("late", try skills(sbd)) == nil }
    try sbd.advanceClock(61_000)
    try hookSkillCall(sbd, c, "notes")

    try waitForLabel(sbd, "late", "work")
  }

  // MARK: Guard: name resolution

  /// Each name with whether the hook must refuse it. A name resolves to the entry that Claude Code would load for
  /// the account and `~/.sb/manager`: a user file beats a cwd file, a skill beats a command, a plugin counts only
  /// when enabled, a plugin's bare name loads it, and `skillOverrides` "off" drops a name.
  static let names: [(name: String, blocked: Bool)] = [
    ("u-work", true), ("c-work", true), ("cmd-work", true), ("dup", false), ("both", false), ("p:s", true),
    ("p:pc", true), ("s", true), ("pc", true), ("q:qs", false), ("qs", false), ("bundled-review", true),
    ("cfg-only", true), ("forced-safe", false), ("off-work", false), ("nope", false), ("clear", false),
    ("flaky", false), ("forced-work", true),
  ]

  /// A Manager whose account and cwd hold one skill for each row of `names`, after every label has landed.
  func nameTable() throws -> (Instance, SessionSummary) {
    let sbd = try instance(config: ["managerSkills": ["work": ["cfg-only", "forced-work"], "safe": ["forced-safe"]]])
    let account = sbd.account("A")
    let cwd = "\(sbd.home.managerFolder)/.claude"
    let safe = "Append to the notes file. LABEL-SAFE"
    try writeSkill(account, "u-work")
    try writeSkill(cwd, "c-work")
    try write("Run the pipeline.\n", to: "\(account)/commands/cmd-work.md")
    try writeSkill(account, "dup", safe)
    try writeSkill(cwd, "dup")
    try writeSkill(account, "both", safe)
    try write("Run the pipeline.\n", to: "\(account)/commands/both.md")
    try writeSkill(account, "off-work")
    try writeSkill(account, "forced-safe")
    try writeSkill(account, "forced-work", safe)
    try writeSkill(account, "flaky", "BAD-SKILL")
    let p = "\(sbd.home.path)/plugin-cache/p/1.0.0"
    let q = "\(sbd.home.path)/plugin-cache/q/1.0.0"
    try writeSkill(p, "s")
    try write("Run the pipeline.\n", to: "\(p)/commands/pc.md")
    try writeSkill(q, "qs")
    let plugins: JSON = [
      "version": 2,
      "plugins": [
        "p@market": [["scope": "user", "installPath": .string(p)]],
        "q@market": [["scope": "user", "installPath": .string(q)]],
      ],
    ]
    try write(plugins.text, to: "\(account)/plugins/installed_plugins.json")
    let settings: JSON = ["enabledPlugins": ["p@market": true], "skillOverrides": ["off-work": "off"]]
    try write(settings.text, to: "\(account)/settings.json")
    // Claude Code's listing names every skill and command that it loads, and `slash-commands` takes its rows from
    // the listing when there is one. It leaves out the skill that `skillOverrides` turns off and the plugin that
    // settings don't enable.
    let loaded = ["u-work", "c-work", "cmd-work", "dup", "both", "forced-safe", "forced-work", "flaky"]
    try writeListing(
      sbd,
      [("bundled-review", "Reviews a diff."), ("p:s", "The s skill."), ("p:pc", nil)] + loaded.map { ($0, nil) })
    let c = try newConversation(sbd)
    // The stub writes the listing into the transcript before the first prompt, and relabel scans it.
    try prompt(sbd, c, "hello")
    try sbd.sb("manager", "skills", "relabel")
    for name in ["u-work", "c-work", "cmd-work", "p:s", "p:pc", "bundled-review"] {
      try waitForLabel(sbd, name, "work")
    }
    for name in ["dup", "both"] { try waitForLabel(sbd, name, "safe") }
    try waitForError(sbd, "flaky")
    return (sbd, c)
  }

  @Test func everyNameResolvesToTheEntryThatClaudeCodeLoads() throws {
    let (sbd, c) = try nameTable()

    for (name, blocked) in Self.names {
      let prompt = try hookPrompt(sbd, c, "/\(name) x")
      let call = try hookSkillCall(sbd, c, name)
      #expect(isBlock(prompt) == blocked, "/\(name): \(prompt.text)")
      #expect(isDeny(call) == blocked, "Skill \(name): \(call.text)")
    }
  }

  // MARK: Parity

  /// The names whose `slash-commands` row the parity test requires: a user skill, a plugin skill and a plugin
  /// command, a listing-only bundled skill, a work file forced safe and a safe file forced work, a safe label, an
  /// unlabeled failure, and a built-in.
  static let slashNames = [
    "u-work", "p:s", "p:pc", "bundled-review", "forced-safe", "forced-work", "dup", "flaky", "clear",
  ]

  /// The hook, for a prompt and for a Skill call, refuses a name exactly when its `manager-skills` row says `work`.
  /// The `slash-commands` row that the app reads carries the same label as the `manager-skills` row.
  @Test func theHookAgreesWithTheManagerSkillsRowOfEveryName() throws {
    let (sbd, c) = try nameTable()
    let rows = try skills(sbd)
    try #require(rows.count >= 10, "\(rows.map(\.text))")

    for row in rows {
      let name = try #require(row["name"]?.string)
      let work = row["label"]?.string == "work"
      let prompt = try hookPrompt(sbd, c, "/\(name)")
      let call = try hookSkillCall(sbd, c, name)
      #expect(isBlock(prompt) == work, "/\(name): row \(row.text), hook \(prompt.text)")
      #expect(isDeny(call) == work, "Skill \(name): row \(row.text), hook \(call.text)")
    }

    let slash = try slashRows(sbd, c.id)
    for name in Self.slashNames {
      try #require(slash[name] != nil, "no slash-commands row for \(name): \(slash.keys.sorted())")
    }
    for (name, slashRow) in slash {
      let label = slashRow["label"]?.string
      let skill = row(name, rows)
      #expect(
        label == skill?["label"]?.string,
        "\(name): slash-commands \(slashRow.text), manager-skills \(skill?.text ?? "none")")
      let prompt = try hookPrompt(sbd, c, "/\(name)")
      let call = try hookSkillCall(sbd, c, name)
      #expect(isBlock(prompt) == (label == "work"), "/\(name): slash-commands \(slashRow.text), hook \(prompt.text)")
      #expect(isDeny(call) == (label == "work"), "Skill \(name): slash-commands \(slashRow.text), hook \(call.text)")
    }
  }
}

/// `sb send --run-here` lets one message's work skill run in a Manager conversation, with the skills that its turn
/// calls. Only the user can arm it: sbd refuses it from Claude and for a session that is not manager-kind, and a
/// host can't send the key.
@Suite(.blocking(timeLimit: .seconds(180))) struct ManagerSkillBypassTests: ManagerSkillSuite {
  /// The run-here turn calls the Skill tool for `go` itself, which the bypass lets through until its Stop.
  @Test func runHereFromATerminalRunsTheSkillAndItsSkillCallsForOneTurn() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)

    try sbd.sb("send", c.id, "--run-here", "/go x skill go")

    try sbd.waitFor(c.id, "the run-here reply", timeout: 30) { $0.lastReply == "Done: /go x skill go" }
    let bypassed = try sbd.events(c.id, kind: "skill_bypassed")
    #expect(bypassed.first?.data["skill"]?.string == "go")
    #expect(try sbd.events(c.id, kind: "skill_blocked").isEmpty)
    #expect(denials(sbd, c).isEmpty)
    #expect(try sent(sbd, c.id, "/go x skill go").first?.data["runHere"]?.bool == true)
  }

  @Test func theNextSlashGoAfterARunHereTurnIsBlockedAgain() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)
    try sbd.sb("send", c.id, "--run-here", "/go x")
    try sbd.waitFor(c.id, "the run-here reply", timeout: 30) { $0.lastReply == "Done: /go x" }

    try sbd.sb("send", c.id, "/go y")

    try waitForEvents(sbd, c.id, "skill_blocked")
    try prompt(sbd, c, "after")
    #expect(!sbd.transcriptContains(c, "Done: /go y"))
  }

  @Test func aSkillCallAfterTheRunHereTurnIsDenied() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)
    try sbd.sb("send", c.id, "--run-here", "/go x")
    try sbd.waitFor(c.id, "the run-here reply", timeout: 30) { $0.lastReply == "Done: /go x" }

    try sbd.sb("send", c.id, "skill go")

    try sbd.waitFor(c.id, "the denied call's reply", timeout: 30) { $0.lastReply?.hasPrefix("Denied:") == true }
  }

  /// The app sends `runHere` on the `send` request without `from` or `insideClaude`.
  @Test func theSendRequestWithRunHereRunsTheSkill() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)

    _ = try sbd.client.call("send", ["session": .string(c.id), "text": "/go x", "runHere": true])

    try sbd.waitFor(c.id, "the run-here reply", timeout: 30) { $0.lastReply == "Done: /go x" }
    #expect(try sbd.events(c.id, kind: "skill_bypassed").count == 1)
  }

  /// sbd arms the bypass in the branch that launches claude with the message as its prompt.
  @Test func runHereToAStoppedConversationArmsTheLaunchPrompt() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)
    try sbd.sb("stop", c.id)
    try sbd.waitFor(c.id, "the stop") { !$0.live }

    let delivery = try sbd.sb("send", c.id, "--run-here", "/go x")

    #expect(delivery.contains("resumed"), "\(delivery)")
    try sbd.waitFor(c.id, "the run-here reply", timeout: 30) { $0.lastReply == "Done: /go x" }
    #expect(try sbd.events(c.id, kind: "skill_bypassed").count == 1)
    #expect(try sbd.events(c.id, kind: "skill_blocked").isEmpty)
  }

  enum EarlyStop: CaseIterable {
    /// `sb stop`, which records `stopped`.
    case stopped
    /// SIGTERM before SessionStart and before the unreported fallback, which records no event.
    case killed
  }

  /// A claude that ends before it takes the run-here launch prompt leaves no bypass for the next claude's `/go`.
  @Test(arguments: EarlyStop.allCases) func aRunHereLaunchThatEndsBeforeItsPromptLeavesTheNextGoBlocked(
    _ how: EarlyStop
  ) throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)
    try sbd.sb("stop", c.id)
    try sbd.waitFor(c.id, "the stop") { $0.claudePid == nil }
    sbd.hold("hold-start")
    try #require(try sbd.sb("send", c.id, "--run-here", "/go x").contains("resumed"))
    let pid = try #require(try sbd.waitFor(c.id, "claude to run") { $0.claudePid != nil }.claudePid)
    switch how {
    case .stopped: try sbd.sb("stop", c.id)
    case .killed: kill(pid_t(pid), SIGTERM)
    }
    try sbd.waitFor(c.id, "claude to end") { $0.claudePid == nil }
    try sbd.release("hold-start")

    let delivery = try sbd.sb("send", c.id, "/go y")

    #expect(delivery.contains("resumed"), "\(delivery)")
    try waitForEvents(sbd, c.id, "skill_blocked")
    #expect(try sbd.events(c.id, kind: "skill_bypassed").isEmpty)
  }

  /// A run-here message that waits in the queue arms nothing until sbd pastes it. The `/go y` pasted before it
  /// would get past the gate if the bypass were armed when the run-here message was queued.
  @Test func aQueuedRunHereMessageArmsOnlyWhenPasted() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)
    try sbd.sb("send", c.id, "slow held")
    try sbd.waitForStubStatus(c, "busy")
    try #require(try sbd.sb("send", c.id, "/go y").contains("queued"))
    try #require(try sbd.sb("send", c.id, "--run-here", "/go x").contains("queued"))

    sbd.hold("report")

    try sbd.waitFor(c.id, "the run-here reply", timeout: 30) { $0.lastReply == "Done: /go x" }
    #expect(try sbd.events(c.id, kind: "skill_blocked").count == 1)
    #expect(try sbd.events(c.id, kind: "skill_bypassed").count == 1)
    #expect(!sbd.transcriptContains(c, "Done: /go y"))
  }

  /// A paused conversation holds the run-here message. The resume pastes it after the resume message, and it arms
  /// the bypass then.
  @Test func aHeldRunHereMessageArmsWhenTheResumePastesIt() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)
    try sbd.pauseJSON(c.id)
    try sbd.waitForPausedExit(c.id)
    try sbd.sb("send", c.id, "--run-here", "/go x")
    let held = try #require(try sent(sbd, c.id, "/go x").first)
    #expect(held.data["held"]?.bool == true)

    try sbd.sb("resume", c.id)

    try sbd.waitFor(c.id, "the run-here reply", timeout: 30) { $0.lastReply == "Done: /go x" }
    #expect(try sbd.events(c.id, kind: "skill_bypassed").count == 1)
    #expect(try sbd.events(c.id, kind: "skill_blocked").isEmpty)
  }

  /// The next UserPromptSubmit clears the armed bypass, whatever its prompt is. So after a different prompt, the
  /// run-here message is blocked.
  @Test func aDifferentPromptBeforeTheRunHereMessageDropsTheBypass() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)
    sbd.hold("hold")
    try sbd.sb("send", c.id, "--run-here", "/go x")
    try sbd.waitFor("the stub to read /go x") { sbd.stubInputCount("/go x") >= 1 }

    let other = try hookPrompt(sbd, c, "hello again")
    sbd.hold("report")

    #expect(!isBlock(other), "\(other.text)")
    try waitForEvents(sbd, c.id, "skill_blocked")
    try prompt(sbd, c, "after")
    #expect(try sbd.events(c.id, kind: "skill_bypassed").isEmpty)
    #expect(!sbd.transcriptContains(c, "Done: /go x"))
  }

  @Test func runHereTextWithoutACommandArmsNothing() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)
    try sbd.sb("send", c.id, "--run-here", "hello there")
    try sbd.waitFor(c.id, "the reply", timeout: 30) { $0.lastReply == "Done: hello there" }

    try sbd.sb("send", c.id, "/go x")

    try waitForEvents(sbd, c.id, "skill_blocked")
    #expect(try sbd.events(c.id, kind: "skill_bypassed").isEmpty)
  }

  // MARK: Guard: only the user arms it

  /// Whether sbd refuses a `send` request with `runHere` and the sender fields, with the refusal of D20.
  func refusesRunHere(_ sbd: Instance, _ c: SessionSummary, _ sender: [String: JSON]) -> Bool {
    let args: [String: JSON] = ["session": .string(c.id), "text": "/go x", "runHere": true]
    do {
      _ = try sbd.client.call("send", args.merging(sender) { $1 })
      return false
    } catch {
      #expect("\(error)".contains("runs a work skill in a Manager conversation"), "\(error)")
      return true
    }
  }

  enum FromClaude: CaseIterable {
    /// `sb send --run-here` inside Claude Code.
    case claudeCodeCLI
    /// `sb send --run-here` with only `SB_SESSION_ID` set.
    case sessionCLI
    /// A `send` request that carries `from`.
    case requestFrom
    /// A `send` request that carries `insideClaude`.
    case requestInsideClaude
  }

  @Test(arguments: FromClaude.allCases) func runHereFromClaudeIsRefusedAndSendsNothing(_ how: FromClaude) throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)

    let refused: Bool
    switch how {
    case .claudeCodeCLI:
      refused = try sbd.run(["send", c.id, "--run-here", "/go x"], env: ["CLAUDECODE": "1"]).status != 0
    case .sessionCLI:
      refused = try sbd.run(["send", c.id, "--run-here", "/go x"], env: ["SB_SESSION_ID": c.id]).status != 0
    case .requestFrom:
      refused = refusesRunHere(sbd, c, ["from": .string(c.id)])
    case .requestInsideClaude:
      refused = refusesRunHere(sbd, c, ["insideClaude": true])
    }

    #expect(refused)
    #expect(try sent(sbd, c.id, "/go x").isEmpty)
    #expect(try sbd.events(c.id, kind: "skill_bypassed").isEmpty)
  }

  /// The MCP `send` tool never forwards `runHere`. Whether it rejects the key or drops it, the skill doesn't run.
  @Test func anMCPSendCantRunAWorkSkill() throws {
    let sbd = try instance()
    let c = try workGoConversation(sbd)
    let mcp = try MCPClient(sbd)

    let result = try mcp.call("send", ["session": .string(c.id), "text": "/go x", "runHere": true])

    if !result.isError {
      try waitForEvents(sbd, c.id, "skill_blocked")
      try prompt(sbd, c, "after")
    }
    #expect(try sbd.events(c.id, kind: "skill_bypassed").isEmpty)
    #expect(!sbd.transcriptContains(c, "Done: /go x"))
  }

  @Test func runHereToAWorkSessionIsRefused() throws {
    let sbd = try instance()
    try workGoConversation(sbd)
    let w = try sbd.new(prompt: "hello")
    try sbd.waitFor(w.id, "the work session's reply") { $0.lastReply == "Done: hello" }

    let result = try sbd.run(["send", w.id, "--run-here", "/go x"])

    #expect(result.status != 0, "\(result.stdout)")
    #expect(try sent(sbd, w.id, "/go x").isEmpty)
  }
}

/// A hook that arrives through a host's socket carries a stamp, and the gate skips it because a host's hook answer
/// never reaches claude. A Manager conversation never runs on a host, so its hook can't arrive that way at all.
@Suite(.blocking(timeLimit: .seconds(240))) struct ManagerSkillRemoteHookTests: ManagerSkillSuite {
  func remote() throws -> Instance {
    let sbd = try Instance.remote(accounts: ["A"])
    try sbd.sb("account", "use", "A")
    return sbd
  }

  @Test func aManagersPromptOnAHostsSocketIsRefusedAndBlocksNothing() throws {
    let sbd = try remote()
    let c = try workGoConversation(sbd)
    try sbd.connectHost("mini")
    let payload: JSON = [
      "hook_event_name": "UserPromptSubmit", "session_id": .string(c.claudeSessionId), "prompt": "/go x",
      "permission_mode": "default",
    ]

    let answer = try sbd.sendLine(
      Instance.hookLine(session: .string(c.id), payload: payload, id: Instance.eventId(ns: Instance.clockNs())),
      to: sbd.hostSocket("mini"))

    #expect(answer?["ok"] == false, "\(answer?.text ?? "no answer")")
    #expect(try sbd.events(c.id, kind: "skill_blocked").isEmpty)
  }

  /// A remote session's hooks arrive stamped. Its `/go` runs, whatever label the Mac's Manager account holds.
  @Test func aStampedPromptOfARemoteSessionIsNotGated() throws {
    let sbd = try remote()
    try workGoConversation(sbd)
    let s = try sbd.startOnHost()

    try sbd.sb("send", s.id, "/go x")

    try sbd.waitFor(s.id, "the remote reply", timeout: 60) { $0.lastReply == "Done: /go x" }
    #expect(try sbd.events(s.id, kind: "skill_blocked").isEmpty)
    #expect(try sbd.events(s.id, kind: "skill_unchecked").isEmpty)
  }
}
