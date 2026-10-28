import Foundation
import Testing

@testable import SwitchboardCore

private func writeTranscript(_ lines: [JSON], in dir: String, newlineAtEnd: Bool = true) throws -> String {
  let path = "\(dir)/transcript.jsonl"
  try (lines.map(\.text).joined(separator: "\n") + (newlineAtEnd ? "\n" : "")).write(
    toFile: path, atomically: true, encoding: .utf8)
  return path
}

private func userLine(_ content: JSON, at time: String) -> JSON {
  ["type": "user", "isSidechain": false, "timestamp": .string(time), "message": ["role": "user", "content": content]]
}

private func assistantLine(_ blocks: [JSON], at time: String, type: String = "assistant", sidechain: Bool = false)
  -> JSON
{
  [
    "type": .string(type), "isSidechain": .bool(sidechain), "timestamp": .string(time),
    "message": ["role": "assistant", "content": .array(blocks)],
  ]
}

private func textBlock(_ text: String) -> JSON { ["type": "text", "text": .string(text)] }

private let toolUseBlock: JSON = ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "make test"]]

@Suite struct TranscriptTests {
  @Test func tailReadsTheLastMainReplyAndTheLastTimestamp() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = try writeTranscript(
      [
        userLine("Fix the parser.", at: "2026-10-25T10:00:00.000Z"),
        assistantLine([textBlock("I'll look at the parser.")], at: "2026-10-25T10:00:01.000Z"),
        assistantLine([toolUseBlock], at: "2026-10-25T10:00:02.000Z"),
        userLine([["type": "tool_result", "tool_use_id": "t1", "content": "ok"]], at: "2026-10-25T10:00:03.000Z"),
        assistantLine(
          [["type": "thinking", "thinking": "Ask before pushing."], textBlock("Want me to push?")],
          at: "2026-10-25T10:00:04.000Z"),
        assistantLine([textBlock("A request blob.")], at: "2026-10-25T10:00:04.500Z", type: "api-request-blob"),
        assistantLine([textBlock("A subagent's reply.")], at: "2026-10-25T10:00:05.250Z", sidechain: true),
        ["type": "last-prompt", "lastPrompt": "Fix the parser."],
      ], in: dir)

    let tail = Transcript.tail(path)

    #expect(tail == TranscriptTail(lastReply: "Want me to push?", lastActivity: 1_792_922_405_250, hasReplies: true))
  }

  @Test func tailKeepsTwoLinesApartWhenAReadStartsAtTheNewlineBetweenThem() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let reply = assistantLine([textBlock("Want me to push?")], at: "2026-10-25T10:00:00.000Z")
    let base = userLine("", at: "2026-10-25T10:00:01.000Z").text.utf8.count
    // The first read takes the last 64 KB. With a last line of 65,534 bytes,
    // that read starts at the newline after the reply. The sizes around it
    // move the newline to each side of that boundary.
    for size in 65_530...65_540 {
      let last = userLine(.string(String(repeating: "x", count: size - base)), at: "2026-10-25T10:00:01.000Z")
      let path = try writeTranscript([reply, last], in: dir)
      #expect(Transcript.tail(path).lastReply == "Want me to push?", "last line of \(size) bytes")
    }
  }

  @Test func tailReadsAReplyFarLargerThanAReadChunk() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    // About 300 KB, with multibyte characters and JSON escapes on every line.
    let reply = String(repeating: "Ünïcödé ⏺ \"quoted\"\n", count: 12_000) + "Want me to push?"
    let path = try writeTranscript(
      [
        userLine("Write it all out.", at: "2026-10-25T10:00:00.000Z"),
        assistantLine([textBlock(reply)], at: "2026-10-25T10:00:01.000Z"),
        userLine(
          [["type": "tool_result", "tool_use_id": "t1", "content": .string(String(repeating: "x", count: 200_000))]],
          at: "2026-10-25T10:00:02.000Z"),
      ], in: dir)

    let tail = Transcript.tail(path)

    #expect(tail.lastReply?.utf8.count == reply.utf8.count)
    let whole = tail.lastReply == reply
    #expect(whole)
    #expect(tail.lastActivity == 1_792_922_402_000)
  }

  @Test func tailReadsAReplyThatHoldsAUnicodeLineSeparator() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let reply = "Done.\u{2028}Want me to push?"
    // JSON allows a raw U+2028 inside a string, and Claude writes it raw.
    let line = assistantLine([textBlock("PLACEHOLDER")], at: "2026-10-25T10:00:01.000Z").text
      .replacingOccurrences(of: "PLACEHOLDER", with: reply)
    let path = "\(dir)/transcript.jsonl"
    try (userLine("Go.", at: "2026-10-25T10:00:00.000Z").text + "\n" + line + "\n").write(
      toFile: path, atomically: true, encoding: .utf8)

    #expect(Transcript.tail(path).lastReply == reply)
  }

  @Test func tailOfOnlyUserLinesHasNoReplyButHasTheLastTimestamp() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = try writeTranscript(
      [userLine("First.", at: "2026-10-25T10:00:00.000Z"), userLine("Second.", at: "2026-10-25T10:00:05.250Z")],
      in: dir, newlineAtEnd: false)

    let tail = Transcript.tail(path)

    #expect(tail == TranscriptTail(lastReply: nil, lastActivity: 1_792_922_405_250, hasReplies: false))
  }

  @Test func tailSkipsALastAssistantLineThatHoldsOnlyAToolCall() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = try writeTranscript(
      [
        userLine("Run the tests.", at: "2026-10-25T10:00:00.000Z"),
        assistantLine([textBlock("I'll run the tests.")], at: "2026-10-25T10:00:01.000Z"),
        assistantLine([toolUseBlock], at: "2026-10-25T10:00:02.000Z"),
      ], in: dir)

    let tail = Transcript.tail(path)

    #expect(tail == TranscriptTail(lastReply: "I'll run the tests.", lastActivity: 1_792_922_402_000, hasReplies: true))
  }

  @Test func tailCountsAToolCallWithoutTextAsAReply() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = try writeTranscript(
      [
        userLine("Run the tests.", at: "2026-10-25T10:00:00.000Z"),
        assistantLine([toolUseBlock], at: "2026-10-25T10:00:01.000Z"),
      ], in: dir)

    let tail = Transcript.tail(path)

    #expect(tail == TranscriptTail(lastReply: nil, lastActivity: 1_792_922_401_000, hasReplies: true))
  }

  @Test(arguments: [("assistant", true), ("api-request-blob", false)])
  func tailIgnoresAssistantTextOutsideTheMainConversation(_ type: String, _ sidechain: Bool) throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = try writeTranscript(
      [
        userLine("Go.", at: "2026-10-25T10:00:00.000Z"),
        assistantLine(
          [textBlock("Not the main reply.")], at: "2026-10-25T10:00:01.000Z", type: type, sidechain: sidechain),
      ], in: dir)

    let tail = Transcript.tail(path)

    #expect(tail == TranscriptTail(lastReply: nil, lastActivity: 1_792_922_401_000, hasReplies: false))
  }

  @Test func tailSkipsAPartialLineThatClaudeIsStillWriting() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = try writeTranscript(
      [
        userLine("Go.", at: "2026-10-25T10:00:00.000Z"),
        assistantLine([textBlock("Done.")], at: "2026-10-25T10:00:01.000Z"),
      ], in: dir)
    let partial =
      #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"Half a"#
    let handle = try #require(FileHandle(forWritingAtPath: path))
    handle.seekToEndOfFile()
    handle.write(Data(partial.utf8))
    try handle.close()

    #expect(Transcript.tail(path).lastReply == "Done.")
  }

  @Test func tailOfAMissingOrEmptyFileIsEmpty() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    FileManager.default.createFile(atPath: "\(dir)/empty.jsonl", contents: Data())

    #expect(Transcript.tail("\(dir)/missing.jsonl") == TranscriptTail())
    #expect(Transcript.tail("\(dir)/empty.jsonl") == TranscriptTail())
  }

  @Test func findLooksInEveryProjectFolder() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let projects = "\(dir)/projects"
    let id = UUID().uuidString.lowercased()
    for folder in ["-Users-me-a", "-Users-me-b"] {
      try FileManager.default.createDirectory(atPath: "\(projects)/\(folder)", withIntermediateDirectories: true)
    }
    FileManager.default.createFile(
      atPath: "\(projects)/-Users-me-a/\(UUID().uuidString.lowercased()).jsonl", contents: nil)
    FileManager.default.createFile(atPath: "\(projects)/-Users-me-b/\(id).jsonl", contents: nil)

    #expect(Transcript.find(id, projects: projects) == "\(projects)/-Users-me-b/\(id).jsonl")
  }

  @Test func findIsNilWhenNoProjectFolderHoldsTheSession() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let projects = "\(dir)/projects"
    let id = UUID().uuidString.lowercased()
    try FileManager.default.createDirectory(atPath: "\(projects)/-Users-me-a", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: "\(projects)/-Users-me-a/\(id).jsonl", contents: nil)

    #expect(Transcript.find(UUID().uuidString.lowercased(), projects: projects) == nil)
    #expect(Transcript.find(String(id.prefix(8)), projects: projects) == nil)
    #expect(Transcript.find(id, projects: "\(dir)/missing") == nil)
  }
}

private let userHome = NSHomeDirectory()
private let defaultAccountForms = [
  "~/.claude", "~/.claude/", "\(userHome)/.claude", "\(userHome)/.claude/", "\(userHome)//.claude",
  "\(userHome)/./.claude",
]
private let otherAccountForms = ["~/.claude-personal", "~/.claudex", "~/.claude/sub", "/tmp/.claude", "~"]

@Suite struct ClaudeAccountTests {
  @Test func normalizeExpandsTheTildeAndDropsATrailingSlash() {
    #expect(ClaudeAccount.normalize("~/.claude-personal/") == "\(userHome)/.claude-personal")
    #expect(ClaudeAccount.defaultFolder == "\(userHome)/.claude")
  }

  @Test(arguments: defaultAccountForms)
  func everyFormOfTheDefaultFolderIsTheDefaultAccount(_ folder: String) {
    #expect(ClaudeAccount.isDefault(folder))
  }

  @Test(arguments: otherAccountForms)
  func anotherFolderIsNotTheDefaultAccount(_ folder: String) {
    #expect(!ClaudeAccount.isDefault(folder))
  }

  @Test(arguments: defaultAccountForms)
  func applyRemovesClaudeConfigDirForTheDefaultAccountAndKeepsOtherKeys(_ folder: String) {
    var env = ["CLAUDE_CONFIG_DIR": "\(userHome)/.claude-personal", "PATH": "/usr/bin", "SB_HOME": "/tmp/sb"]

    ClaudeAccount.apply(folder, to: &env)

    #expect(env == ["PATH": "/usr/bin", "SB_HOME": "/tmp/sb"])
  }

  @Test(arguments: ["~/.claude-personal", "~/.claude-personal/", "\(NSHomeDirectory())/.claude-personal"])
  func applySetsTheExpandedFolderForAnotherAccount(_ folder: String) {
    var env = ["CLAUDE_CONFIG_DIR": "/elsewhere", "PATH": "/usr/bin"]

    ClaudeAccount.apply(folder, to: &env)

    #expect(env == ["CLAUDE_CONFIG_DIR": "\(userHome)/.claude-personal", "PATH": "/usr/bin"])
  }

  @Test(arguments: defaultAccountForms + otherAccountForms)
  func applyAndCommandAgreeWithIsDefault(_ folder: String) {
    var env = ["CLAUDE_CONFIG_DIR": "/elsewhere"]
    ClaudeAccount.apply(folder, to: &env)
    let isDefault = ClaudeAccount.isDefault(folder)

    #expect(env["CLAUDE_CONFIG_DIR"] == (isDefault ? nil : ClaudeAccount.normalize(folder)))
    #expect((ClaudeAccount.command("claude stop x", in: folder) == "claude stop x") == isDefault)
  }

  @Test func commandRunsAsGivenForTheDefaultAccount() {
    #expect(ClaudeAccount.command("claude stop deadbeef", in: "~/.claude") == "claude stop deadbeef")
  }

  @Test func commandSetsClaudeConfigDirForAnotherAccount() {
    #expect(
      ClaudeAccount.command("claude stop deadbeef", in: "~/.claude-personal/")
        == "CLAUDE_CONFIG_DIR='\(userHome)/.claude-personal' claude stop deadbeef")
  }

  @Test func commandQuotesAFolderThatTheShellWouldSplit() {
    #expect(
      ClaudeAccount.command("claude stop x", in: "/Volumes/My Disk/Bob's claude")
        == #"CLAUDE_CONFIG_DIR='/Volumes/My Disk/Bob'\''s claude' claude stop x"#)
  }

  @Test func discoverFindsTheDefaultAccountAndEachDashedFolderThatHoldsAConfig() throws {
    let home = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: home) }
    for folder in [".claude", ".claude-personal", ".claude-automation", ".claude-prompts", ".claudex"] {
      try FileManager.default.createDirectory(atPath: "\(home)/\(folder)", withIntermediateDirectories: true)
    }
    for folder in [".claude-personal", ".claude-automation", ".claudex"] {
      FileManager.default.createFile(atPath: "\(home)/\(folder)/.claude.json", contents: Data("{}".utf8))
    }

    let accounts = ClaudeAccount.discover(home: home)

    #expect(
      accounts
        == [".claude", ".claude-automation", ".claude-personal"].map { ClaudeAccount.normalize("\(home)/\($0)") })
  }

  @Test func discoverListsTheDefaultAccountInAnEmptyHome() throws {
    let home = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: home) }

    #expect(ClaudeAccount.discover(home: home) == [ClaudeAccount.normalize("\(home)/.claude")])
  }
}

@Suite struct ClaudeSessionTests {
  static let account = "/Users/me/.claude-personal"

  @Test func listReadsInteractiveAndBackgroundRows() throws {
    let text = """
      [
        {"pid": 57910, "cwd": "/a", "kind": "interactive", "startedAt": 1792962894692, "sessionId": "u1",
         "name": "docket-e2", "status": "busy"},
        {"pid": 57911, "cwd": "/b", "kind": "background", "startedAt": 1792962894692, "sessionId": "u2",
         "name": "fix-ci", "status": "idle", "id": "701cd24a", "state": "blocked"},
        {"cwd": "/c", "kind": "background", "startedAt": 1792962894692, "sessionId": "u3", "id": "9f3e0b12",
         "state": "stopped"},
        {"pid": 1, "kind": "interactive"}
      ]
      """

    let sessions = try ClaudeSession.list(fromAgents: text, account: Self.account, seen: 42)

    #expect(
      sessions == [
        ClaudeSession(
          id: "u1", name: "docket-e2", cwd: "/a", account: Self.account, status: "busy", pid: 57910, seen: 42),
        ClaudeSession(
          id: "u2", name: "fix-ci", cwd: "/b", account: Self.account, status: "idle", job: "701cd24a", pid: 57911,
          seen: 42),
        ClaudeSession(id: "u3", cwd: "/c", account: Self.account, job: "9f3e0b12", seen: 42),
      ])
  }

  @Test func listOfNoSessionsIsEmpty() throws {
    #expect(try ClaudeSession.list(fromAgents: "[]\n", account: Self.account, seen: 42).isEmpty)
  }

  @Test(arguments: ["not json", "{}", ""])
  func listThrowsNamingTheAccountWhenTheOutputIsNotAJSONList(_ text: String) {
    let error = #expect(throws: APIError.self) {
      try ClaudeSession.list(fromAgents: text, account: Self.account, seen: 42)
    }
    #expect(error?.description.contains(Self.account) == true)
  }

  @Test func aSessionRunsOnlyWhileItHasAPid() {
    #expect(ClaudeSession(id: "u1", cwd: "/a", account: Self.account, pid: 57910).running)
    #expect(!ClaudeSession(id: "u1", cwd: "/a", account: Self.account).running)
  }
}

private func importedEvent(at t: Int64, reply: String?, activity: Int64?, hasReplies: Bool) -> Event {
  event(
    "imported", t,
    [
      "account": "/Users/me/.claude-personal", "lastReply": reply.map(JSON.string) ?? .null,
      "lastActivity": activity.map { JSON.number(Double($0)) } ?? .null, "hasReplies": .bool(hasReplies),
    ])
}

@Suite struct ImportedAttention {
  static let transcriptTime: Int64 = 1_792_922_405_250
  static let importTime = transcriptTime + 60_000

  func verdict(reply: String?, hasReplies: Bool) -> Verdict {
    let f = facts([
      importedEvent(at: Self.importTime, reply: reply, activity: Self.transcriptTime, hasReplies: hasReplies)
    ])
    return Attention.evaluate(session(), f, now: Self.importTime + 1000)
  }

  @Test func anImportedQuestionNeedsAnAnswer() {
    #expect(
      verdict(reply: "Which schema should I use, A or B?", hasReplies: true)
        == Verdict(state: .needsYou, reason: "answer: Which schema should I use, A or B?"))
  }

  @Test func anImportedOfferCanContinue() {
    #expect(
      verdict(reply: "I wrote the parser. Want me to run the tests?", hasReplies: true)
        == Verdict(state: .canContinue, reason: "offered: Want me to run the tests?"))
  }

  @Test func anImportedSessionWithRepliesButNoTextNeedsYouToReadIt() {
    #expect(
      verdict(reply: nil, hasReplies: true)
        == Verdict(state: .needsYou, reason: "read its last reply and decide what's next"))
  }

  @Test func anImportedSessionWithoutRepliesNeedsAFirstPrompt() {
    #expect(verdict(reply: nil, hasReplies: false) == Verdict(state: .needsYou, reason: "give it a first prompt"))
  }

  @Test func importCountsAReplyAsAPromptThatCameBeforeIt() {
    let replied = facts([importedEvent(at: Self.importTime, reply: nil, activity: nil, hasReplies: true)])
    let silent = facts([importedEvent(at: Self.importTime, reply: nil, activity: nil, hasReplies: false)])

    #expect(replied.prompts == 1)
    #expect(silent.prompts == 0)
  }

  @Test func importSetsLastActivityToTheTranscriptTimeInsteadOfTheEventTime() {
    let f = facts([
      importedEvent(at: Self.importTime, reply: "Want me to push?", activity: Self.transcriptTime, hasReplies: true)
    ])

    #expect(f.lastActivity == Self.transcriptTime)
  }

  @Test func importWithoutATranscriptTimeIsActiveWhenImported() {
    let f = facts([importedEvent(at: Self.importTime, reply: nil, activity: nil, hasReplies: false)])

    #expect(f.lastActivity == Self.importTime)
  }

  @Test func anImportedSessionIdleForOverTwoDaysByItsTranscriptIsStale() {
    let later = Self.transcriptTime + Attention.staleAfterMs + 60_000
    let f = facts([
      importedEvent(at: later, reply: "Want me to push?", activity: Self.transcriptTime, hasReplies: true)
    ])

    #expect(Attention.evaluate(session(), f, now: later + 1000).state == .stale)
  }
}
