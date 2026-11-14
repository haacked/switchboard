import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// The answer of `sb context <id> --json`, as JSON, so that a test reads the wire names such as `"anchor": "none"`.
  func contextJSON(_ id: String, _ more: String...) throws -> JSON {
    try #require(JSON.parse(try sb(["context", id, "--json"] + more)))
  }

  /// The answer of `sb context <id> --json`, decoded as the app decodes it.
  func context(_ id: String, _ more: String...) throws -> ItemContext {
    try JSONCoding.decode(ItemContext.self, from: try sb(["context", id, "--json"] + more))
  }

  /// The `item-context` request with raw args, which reach sbd without the CLI's checks.
  func itemContext(_ id: String, steps: JSON? = nil) throws -> ItemContext {
    var args: [String: JSON] = ["session": .string(id)]
    if let steps { args["steps"] = steps }
    return try client.call("item-context", args, as: ItemContext.self)
  }

  /// A session whose turns ended with "Done: <prompt>" for each prompt, in order.
  func repliedSession(_ prompts: [String]) throws -> SessionSummary {
    let s = try new(prompt: prompts[0])
    try waitFor(s.id, "the reply to \(prompts[0])") { $0.lastReply == "Done: \(prompts[0])" }
    for prompt in prompts.dropFirst() {
      try sb("send", s.id, prompt)
      try waitFor(s.id, "the reply to \(prompt)") { $0.lastReply == "Done: \(prompt)" }
    }
    return try get(s.id)
  }

  /// A session whose "hello" turn ended in "Done: hello", once its summary item arrived, with 250 older replies
  /// "s1" to "s250" written before the turn's lines. The stub is idle by then, so nothing else writes the file.
  func seededSession() throws -> SessionSummary {
    let s = try new(prompt: "hello")
    try waitFor(s.id, "the summary item") { $0.lastReply == "Done: hello" && $0.triage?.source == .summary }
    let path = try #require(try events(s.id).compactMap { $0.data["transcript_path"]?.string }.last)
    let turn = try String(contentsOfFile: path, encoding: .utf8)
    let older = (1...250).map { n -> String in
      let line: JSON = [
        "type": "assistant",
        "message": ["role": "assistant", "content": [["type": "text", "text": .string("s\(n)")]]],
      ]
      return line.text + "\n"
    }
    try (older.joined() + turn).write(toFile: path, atomically: true, encoding: .utf8)
    return s
  }
}

/// A session card with one option, which the stub's `card <name>` prompt sets before its Stop.
private let sessionCard =
  #"{"summary": "It finished.", "options": [{"label": "Go on", "action": "send", "message": "Go on."}]}"#

/// `sb context` and the `item-context` request: the transcript steps that lead up to the session's current item.
/// The stub writes the assistant tool_use line of a permission call, with id "c1", before its PreToolUse.
@Suite(.blocking(timeLimit: .seconds(120))) struct TranscriptContextTests {
  // MARK: A held prompt

  @Test func aPermissionPromptAnchorsAtItsToolCall() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "perm touch x")
    let asked = try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }

    let json = try sbd.contextJSON(s.id)
    let context = try sbd.context(s.id)

    #expect(json["anchor"]?.string == "tool")
    #expect(context.ref == asked.triage?.ref)
    #expect(context.ref == asked.cards.first?.ref)
    #expect(context.anchored)
    let last = try #require(context.steps.last)
    #expect(last.kind == .tool)
    #expect(last.tool == "Bash")
    #expect(last.summary?.contains("touch x") == true)
    #expect(last.id == "c1")
  }

  @Test func aQuestionCardAnchorsAtItsCallWithItsFirstQuestion() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "pick fruit")
    try sbd.waitFor(s.id, "the card") { $0.cards.first?.kind == .question }

    let json = try sbd.contextJSON(s.id)
    let context = try sbd.context(s.id)

    #expect(json["anchor"]?.string == "tool")
    #expect(context.anchored)
    #expect(context.steps.last?.tool == "AskUserQuestion")
    #expect(context.steps.last?.summary == "AskUserQuestion Which fruit?")
  }

  /// The prompt's call is the last step, and the replies of the earlier turns come before it.
  @Test func aPermissionPromptAfterEarlierTurnsShowsTheirRepliesBeforeTheCall() throws {
    let sbd = try Instance()
    let s = try sbd.repliedSession(["hello one", "hello two"])
    try sbd.sb("send", s.id, "perm touch x")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }

    let context = try sbd.context(s.id)

    #expect(context.anchored)
    #expect(
      context.steps.map { $0.text ?? "tool:\($0.tool ?? "")" } == ["Done: hello one", "Done: hello two", "tool:Bash"])
    #expect(!context.more)
  }

  // MARK: Reply items

  /// The stub's "ask" reply gives a `.summary` item, and a session named FAIL-SUMMARY gives a `.fallback` item.
  @Test(arguments: [("ask", "t", TriageSource.summary), ("ask", "FAIL-SUMMARY", .fallback), ("offer", "t", .summary)])
  func aReplyItemAnchorsAtTheReply(_ prompt: String, _ name: String, _ source: TriageSource) throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: prompt, name: name)
    let item = try sbd.waitFor(s.id, "the \(source) item") { $0.triage?.source == source }
    let lastReply = try #require(item.lastReply)

    let json = try sbd.contextJSON(s.id)
    let context = try sbd.context(s.id)

    #expect(json["anchor"]?.string == "reply")
    #expect(context.ref?.hasPrefix("stop:") == true)
    #expect(context.ref == item.triage?.ref)
    #expect(context.anchored)
    #expect(context.steps.last?.kind == .text)
    #expect(context.steps.last?.text == lastReply)
  }

  /// Once the user allows the call, the turn ends with a reply, and the context follows the new item.
  @Test func allowingThePromptMovesTheContextToTheReplyItem() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "perm touch x")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }
    let before = try sbd.context(s.id)
    try sbd.sb("allow", s.id)
    let after = try sbd.waitFor(s.id, "the reply item") {
      $0.lastReply == "Ran touch x" && $0.cards.isEmpty && $0.triage?.ref.hasPrefix("stop:") == true
    }

    let json = try sbd.contextJSON(s.id)
    let context = try sbd.context(s.id)

    #expect(context.ref != before.ref)
    #expect(context.ref == after.triage?.ref)
    #expect(json["anchor"]?.string == "reply")
    #expect(context.anchored)
    #expect(context.steps.map { $0.text ?? "tool:\($0.tool ?? "")" } == ["tool:Bash", "Ran touch x"])
  }

  // MARK: Session cards, rules, and no item

  @Test func aSessionCardAnchorsAtTheEnd() throws {
    let sbd = try Instance()
    try sbd.writeCard("c1", sessionCard)
    let s = try sbd.new(prompt: "card c1")
    let item = try sbd.waitFor(s.id, "the session's card") { $0.triage?.source == .session }

    let json = try sbd.contextJSON(s.id)
    let context = try sbd.context(s.id)

    #expect(json["anchor"]?.string == "end")
    #expect(context.ref == item.triage?.ref)
    #expect(context.ref?.hasPrefix("summary:") == true)
    #expect(context.anchored)
    #expect(context.steps.last?.text == "I wrote the card c1.")
  }

  /// A session with no prompt has a rule item and no transcript yet.
  @Test func aRuleItemWithoutATranscriptIsUnanchoredWithNoSteps() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let item = try sbd.waitFor(s.id, "the rule item") { $0.triage?.source == .rule }

    let json = try sbd.contextJSON(s.id)

    #expect(json["anchor"]?.string == "none")
    #expect(json["anchored"] == false)
    #expect(json["steps"] == [])
    #expect(json["more"] == false)
    #expect(json["ref"]?.string == item.triage?.ref)
  }

  /// A working session has no item, so the context anchors at the newest step and has no ref.
  @Test func aSessionWithoutAnItemAnchorsAtTheEndWithoutARef() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "slow 30")
    try sbd.waitFor(s.id, "the running tool") { $0.state == .working && $0.triage == nil }

    let json = try sbd.contextJSON(s.id)

    #expect(json["anchor"]?.string == "end")
    #expect(json["ref"] == nil || json["ref"] == .null)
  }

  // MARK: Steps

  /// sbd clamps `steps` to 1...200. A clamp to 1 gives the anchor and the one step before it.
  @Test func zeroStepsReadAsOneStepBeforeTheAnchor() throws {
    let sbd = try Instance()
    let s = try sbd.seededSession()

    let context = try sbd.itemContext(s.id, steps: 0)

    #expect(context.anchored)
    #expect(context.steps.compactMap(\.text) == ["s250", "Done: hello"])
    #expect(context.more)
  }

  @Test func withoutStepsTheRequestReadsFiveStepsBeforeTheAnchor() throws {
    let sbd = try Instance()
    let s = try sbd.seededSession()

    let context = try sbd.itemContext(s.id)

    #expect(context.steps.compactMap(\.text) == ["s246", "s247", "s248", "s249", "s250", "Done: hello"])
    #expect(context.more)
  }

  /// Without the clamp, the read would return all 251 steps and no more.
  @Test func moreStepsThanTheLimitReadTwoHundredStepsBeforeTheAnchor() throws {
    let sbd = try Instance()
    let s = try sbd.seededSession()

    let context = try sbd.itemContext(s.id, steps: 1_000)

    #expect(context.steps.count == 201)
    #expect(context.steps.first?.text == "s51")
    #expect(context.steps.last?.text == "Done: hello")
    #expect(context.more)
  }

  @Test func theStepsFlagCountsTheStepsBeforeTheAnchor() throws {
    let sbd = try Instance()
    let s = try sbd.seededSession()

    let context = try sbd.context(s.id, "--steps", "1")

    #expect(context.steps.compactMap(\.text) == ["s250", "Done: hello"])
    #expect(context.more)
  }

  // MARK: Errors and the text form

  @Test func anUnknownSessionFails() throws {
    let sbd = try Instance()

    #expect(throws: TestError.self) { try sbd.sb("context", "no-such-session", "--json") }
  }

  @Test func theRequestRefusesAnUnknownSessionAsLookupDoes() throws {
    let sbd = try Instance()

    #expect(throws: APIError.self) { try sbd.itemContext("no-such-session") }
  }

  @Test func theTextFormPrintsTheToolCallOnItsOwnLine() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "perm touch x")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }

    let text = try sbd.sb("context", s.id)

    #expect(text.split(separator: "\n").contains { $0.contains("→ Bash") && $0.contains("touch x") })
  }

  @Test func theTextFormPrintsClaudesReply() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "ask")
    try sbd.waitFor(s.id, "the summary") { $0.triage?.source == .summary }

    let text = try sbd.sb("context", s.id)

    #expect(text.contains("Claude: Which database should I use, Postgres or SQLite?"))
  }

  @Test func helpListsContext() throws {
    let sbd = try Instance()

    #expect(try sbd.sb("help").contains("context <session>"))
  }
}

/// A remote session's transcript lives on its host, so sbd reads it there.
@Suite(.blocking(timeLimit: .seconds(240))) struct RemoteTranscriptContextTests {
  @Test func aPermissionPromptOnTheBoxAnchorsAtItsToolCall() throws {
    let sbd = try Instance.remote()
    let s = try sbd.startOnHost(prompt: "perm touch x")
    try sbd.waitFor(s.id, "the card") { !$0.cards.isEmpty }

    let json = try sbd.contextJSON(s.id)
    let context = try sbd.context(s.id)

    #expect(json["anchor"]?.string == "tool")
    #expect(context.anchored)
    #expect(context.steps.last?.tool == "Bash")
    #expect(context.steps.last?.id == "c1")
  }
}
