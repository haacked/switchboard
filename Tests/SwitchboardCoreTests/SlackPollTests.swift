import Foundation
import Testing

@testable import SwitchboardCore

/// The inputs of the Slack poll tests. The tool and server names are spelled out, so a change to the constants in
/// `SlackPoll` fails here.
private enum PollFx {
  static let structured = "StructuredOutput"
  static let read = "mcp__claude_ai_Slack__slack_read_thread"
  static let profile = "mcp__claude_ai_Slack__slack_read_user_profile"
  static let send = "mcp__claude_ai_Slack__slack_send_message"
  static let server = "claude.ai Slack"
  static let pollTools = [structured, read]
  static let profileTools = [structured, profile]
  /// What claude lists on a fresh sbd, before sbd has learned a deny list.
  static let allSlack = [structured, read, profile, send]

  static let chA = "C0EXAMPLE01"
  static let rootA = "1794965000.000100"
  static let chB = "C0EXAMPLE02"
  static let rootB = "1794965100.000200"
  /// A reply after both roots.
  static let reply1 = "1794965246.462679"
  /// A reply after `reply1`.
  static let reply2 = "1794965300.000300"
  static let other = "U0OTHER"
  static let selfId = "U0EXAMPLESELF"

  static let askA = SlackPoll.Ask(channel: chA, thread: rootA, oldest: nil)
  static let askB = SlackPoll.Ask(channel: chB, thread: rootB, oldest: nil)
  static let keyA = "\(chA)/\(rootA)"
  static let keyB = "\(chB)/\(rootB)"

  static let schema: JSON = ["type": "object", "properties": ["threads": ["type": "array"]]]
  static let system = "Read the threads."

  // MARK: Stream-json lines

  // Every assumption about the shape of claude's stream-json output lives in these functions. They follow claude
  // 2.1 with `--output-format stream-json --verbose`.

  static let connected: JSON = [["name": .string(server), "status": "connected"]]

  static func servers(status: String) -> JSON { [["name": .string(server), "status": .string(status)]] }

  /// The init line. A nil `tools` or `servers` leaves the key out.
  static func initLine(tools: [String]?, servers: JSON? = connected) -> String {
    var o: [String: JSON] = [
      "type": "system", "subtype": "init", "permissionMode": "dontAsk", "session_id": "0b5f2c4e", "model": "haiku",
    ]
    if let tools { o["tools"] = .array(tools.map(JSON.string)) }
    if let servers { o["mcp_servers"] = servers }
    return JSON.object(o).text
  }

  static func system(_ subtype: String) -> String {
    JSON.object(["type": "system", "subtype": .string(subtype), "session_id": "0b5f2c4e"]).text
  }

  static func assistantText(_ text: String) -> String {
    JSON.object(["type": "assistant", "message": ["content": [["type": "text", "text": .string(text)]]]]).text
  }

  static func toolUse(id: String, name: String, input: JSON) -> String {
    JSON.object([
      "type": "assistant",
      "message": [
        "content": [["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]]
      ],
    ]).text
  }

  /// A tool_result whose content is a list of one text block, or a plain string when `plain` is set.
  static func toolResult(id: String, text: String, isError: Bool = false, plain: Bool = false) -> String {
    var block: [String: JSON] = [
      "type": "tool_result", "tool_use_id": .string(id),
      "content": plain ? .string(text) : [["type": "text", "text": .string(text)]],
    ]
    if isError { block["is_error"] = true }
    return JSON.object(["type": "user", "message": ["content": [.object(block)]]]).text
  }

  /// The result envelope. A nil `structured` leaves `structured_output` out.
  static func result(_ structured: JSON?, isError: Bool = false) -> String {
    var o: [String: JSON] = [
      "type": "result", "subtype": isError ? "error_during_execution" : "success", "is_error": .bool(isError),
      "result": .string(structured?.text ?? ""),
      "usage": ["input_tokens": 100, "output_tokens": 20],
      "modelUsage": ["haiku": ["inputTokens": 100, "outputTokens": 20]],
    ]
    if let structured { o["structured_output"] = structured }
    return JSON.object(o).text
  }

  static func lines(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

  // MARK: Thread reads

  static func readInput(_ channel: String, _ ts: String, oldest: String? = nil) -> JSON {
    var o: [String: JSON] = ["channel_id": .string(channel), "message_ts": .string(ts)]
    if let oldest { o["oldest"] = .string(oldest) }
    return .object(o)
  }

  static let noMorePages = "There are no more messages in this thread.\n"

  /// The text block of a `slack_read_thread` result, as the connector gives it: a JSON object whose `messages`
  /// holds the parent message and the newest reply, each with its `From:` and `Message TS:` lines, and whose
  /// `pagination_info` says whether more messages are left.
  static func threadText(
    count: Int, user: String? = other, name: String? = "Alice", ts: String? = reply1,
    body: String = "Looks good to me.",
    pages: String? = noMorePages
  ) -> String {
    var messages = """
      === THREAD PARENT MESSAGE ===
      From: Bob (U0ROOT)
      Time: 2026-11-19 22:52:27 PST
      Message TS: \(rootA)
      Can someone review the flag cache change?

      """
    if count > 0 {
      messages += """
        === THREAD REPLIES (\(count) total) ===

        From: \(name ?? "Someone") (\(user ?? "U0NOBODY"))
        Time: 2026-11-20 02:57:42 PST
        Message TS: \(ts ?? "1794965999.999999")
        \(body)

        """
    } else {
      // The connector spells it this way.
      messages += "No thread messsages"
    }
    return connectorText(messages, pages: pages)
  }

  /// The connector's JSON object around a `messages` text.
  static func connectorText(_ messages: String, pages: String? = noMorePages) -> String {
    var o: [String: JSON] = ["messages": .string(messages)]
    if let pages { o["pagination_info"] = .string(pages) }
    return JSON.object(o).text
  }

  static func answer(
    _ channel: String, _ ts: String, count: Int, last: String?, user: String?, name: String?, ok: Bool = true
  ) -> JSON {
    var o: [String: JSON] = [
      "channel_id": .string(channel), "message_ts": .string(ts), "ok": .bool(ok), "reply_count": .number(Double(count)),
    ]
    if count > 0 {
      if let last { o["last_reply_ts"] = .string(last) }
      if let user { o["last_reply_user_id"] = .string(user) }
      if let name { o["last_reply_user_name"] = .string(name) }
    }
    return .object(o)
  }

  /// One asked thread's part of a poll's stream: its tool call, its tool result, and its answer.
  struct Part {
    var ask: SlackPoll.Ask
    var id: String
    var tool = PollFx.read
    var input: JSON
    var hasCall = true
    var hasResult = true
    var resultId: String?
    var resultText: String
    var resultError = false
    var plainResult = false
    var answer: JSON?

    init(
      _ ask: SlackPoll.Ask, id: String, count: Int = 1, last: String? = PollFx.reply1, user: String? = PollFx.other,
      name: String? = "Alice"
    ) {
      self.ask = ask
      self.id = id
      input = PollFx.readInput(ask.channel, ask.thread, oldest: ask.oldest)
      resultText = PollFx.threadText(count: count, user: user, name: name, ts: last)
      answer = PollFx.answer(ask.channel, ask.thread, count: count, last: last, user: user, name: name)
    }

    /// The answer with one field changed.
    mutating func setAnswer(_ key: String, _ value: JSON?) {
      var o = answer?.object ?? [:]
      o[key] = value
      answer = .object(o)
    }
  }

  static func stream(_ parts: [Part], extraAnswers: [JSON] = [], tools: [String] = pollTools) -> String {
    var out = [initLine(tools: tools)]
    for p in parts where p.hasCall {
      out.append(toolUse(id: p.id, name: p.tool, input: p.input))
      if p.hasResult {
        out.append(toolResult(id: p.resultId ?? p.id, text: p.resultText, isError: p.resultError, plain: p.plainResult))
      }
    }
    out.append(result(["threads": .array(parts.compactMap(\.answer) + extraAnswers)]))
    return lines(out)
  }

  struct Read: Equatable {
    var count: Int
    var ts: String?
    var user: String?
    var name: String?
  }

  enum Outcome: Equatable {
    case read(Read)
    case failed(String)

    var read: Read? {
      if case .read(let r) = self { return r }
      return nil
    }
    var failed: Bool {
      if case .failed = self { return true }
      return false
    }
  }

  /// The scan's time, a little after the replies.
  static let now: Int64 = 1_794_966_000_000

  static func outcomes(_ output: String, asked: [SlackPoll.Ask], now: Int64 = now) throws -> [String: Outcome] {
    try SlackPoll.parseThreads(output, asked: asked, now: now).mapValues { (result) -> Outcome in
      switch result {
      case .success(let r):
        .read(Read(count: Int(r.count), ts: r.lastReplyTs, user: r.lastReplyUser, name: r.lastReplyName))
      case .failure(let error): .failed("\(error)")
      }
    }
  }

  static func goodA() -> Part { Part(askA, id: "toolu_A") }
  static func goodB() -> Part { Part(askB, id: "toolu_B") }
  static let readA = Read(count: 1, ts: reply1, user: other, name: "Alice")

  /// Parses the unchanged thread A beside the thread B parts that a test changed. It requires A's read, so a parse
  /// that refuses every thread fails the test.
  static func outcomeOfB(
    _ parts: Part..., ask: SlackPoll.Ask = askB, extraAnswers: [JSON] = [],
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws -> Outcome {
    let got = try outcomes(stream([goodA()] + parts, extraAnswers: extraAnswers), asked: [askA, ask])
    #expect(got[keyA] == .read(readA), "thread A", sourceLocation: sourceLocation)
    return try #require(got[keyB], "no outcome for thread B", sourceLocation: sourceLocation)
  }

  // MARK: Profile reads

  /// A profile call's stream. The connector wraps the profile's text in a JSON object under `result`.
  static func selfStream(
    input: JSON = [:], tool: String = profile, text: String = "User ID: \(selfId)\nDisplay Name: You\nTitle: Engineer",
    structured: JSON? = ["user_id": .string(selfId)], resultError: Bool = false, resultId: String = "toolu_P",
    hasCall: Bool = true, hasResult: Bool = true, hasEnvelope: Bool = true, plain: Bool = false,
    envelopeError: Bool = false
  ) -> String {
    var out = [initLine(tools: profileTools)]
    if hasCall {
      out.append(toolUse(id: "toolu_P", name: tool, input: input))
      let wrapped = JSON.object(["result": .string(text)]).text
      if hasResult { out.append(toolResult(id: resultId, text: wrapped, isError: resultError, plain: plain)) }
    }
    if hasEnvelope { out.append(result(structured, isError: envelopeError)) }
    return lines(out)
  }

  // MARK: The init check and the line handler

  enum InitOutcome: Equatable {
    case ok
    case extra(Set<String>)
    case refuse(String)

    var refused: Bool {
      if case .refuse = self { return true }
      return false
    }
    var reason: String {
      if case .refuse(let r) = self { return r }
      return ""
    }
  }

  static let account = "~/.claude"

  static func check(_ line: String, allowed: String = read) -> InitOutcome {
    switch SlackPoll.initCheck(line: line, allowed: allowed, account: account) {
    case .ok: .ok
    case .extraTools(let names): .extra(Set(names))
    case .refuse(let reason): .refuse(reason)
    }
  }

  static func check(tools: [String]?, servers: JSON? = connected, allowed: String = read) -> InitOutcome {
    check(initLine(tools: tools, servers: servers), allowed: allowed)
  }

  /// Feeds the lines to a fresh line handler until it refuses one. It returns the refusal, the 1-based number of
  /// the refused line, and the extra tools that the handler recorded. Every assumption about the handler's
  /// interface lives here.
  static func feed(_ lines: [String], allowed: String = read) -> (refusal: String?, at: Int?, extra: Set<String>) {
    let handler = SlackPoll.lineHandler(allowed: allowed, account: account)
    for (i, line) in lines.enumerated() {
      if let reason = handler.onLine(line) { return (reason, i + 1, Set(handler.extraTools)) }
    }
    return (nil, nil, Set(handler.extraTools))
  }

  // MARK: Arguments

  static func args(allowed: String = read, deny: [String] = []) -> [String] {
    SlackPoll.arguments(model: "haiku", schema: schema, system: system, allowed: allowed, deny: deny)
  }

  static func value(after flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
  }

  /// The entries of `--disallowedTools`, or nil without the flag. The flag takes each value up to the next flag,
  /// and a value can list several entries split by commas or spaces.
  static func disallowed(_ args: [String]) -> Set<String>? {
    guard let i = args.firstIndex(of: "--disallowedTools") else { return nil }
    let values = args[(i + 1)...].prefix { !$0.hasPrefix("--") }
    return Set(values.flatMap { $0.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init) })
  }

  /// The tools that claude lists after the arguments' deny list, as claude drops a name that a deny entry names in
  /// full or as its `mcp__<server>` prefix.
  static func listed(after args: [String], from tools: [String] = allSlack) -> [String] {
    let denied = disallowed(args) ?? []
    return tools.filter { name in !denied.contains(name) && !denied.contains { name.hasPrefix($0 + "__") } }
  }
}

/// The suites nest under one name, so `--filter SlackPollTests` runs them all.
@Suite struct SlackPollTests {}

// MARK: - arguments

extension SlackPollTests {
  @Suite struct Arguments {
    @Test func theArgumentsStartWithPrint() {
      #expect(PollFx.args().first == "-p")
    }

    @Test func theOutputIsStreamJSONWithVerbose() {
      let args = PollFx.args()

      #expect(PollFx.value(after: "--output-format", in: args) == "stream-json")
      #expect(args.filter { $0 == "--output-format" }.count == 1)
      #expect(args.contains("--verbose"))
    }

    @Test func theSettingSourcesAreTheUsersOnly() {
      #expect(PollFx.value(after: "--setting-sources", in: PollFx.args()) == "user")
    }

    @Test func thePermissionModeIsDontAsk() {
      #expect(PollFx.value(after: "--permission-mode", in: PollFx.args()) == "dontAsk")
    }

    @Test(arguments: [PollFx.read, PollFx.profile])
    func theAllowedToolIsTheCallsOwnTool(_ allowed: String) {
      #expect(PollFx.value(after: "--allowedTools", in: PollFx.args(allowed: allowed)) == allowed)
    }

    @Test func theBuiltInToolsAreOff() {
      #expect(PollFx.value(after: "--tools", in: PollFx.args()) == "")
    }

    @Test func noSessionIsSavedAndNoSlashCommandRuns() {
      let args = PollFx.args()

      #expect(args.contains("--no-session-persistence"))
      #expect(args.contains("--disable-slash-commands"))
    }

    /// D20: the spike's verified value.
    @Test func theSettingsAreTheSpikesValue() throws {
      let text = try #require(PollFx.value(after: "--settings", in: PollFx.args()))

      let settings = try #require(JSON.parse(text))

      #expect(
        settings
          == [
            "disableAllHooks": true, "autoMemoryEnabled": false, "claudeMdExcludes": ["/Users/**"], "advisorModel": "",
          ])
    }

    /// The call needs the user's claude.ai connectors, which `--strict-mcp-config` would drop.
    @Test func theArgumentsDoNotHoldStrictMCPConfig() {
      #expect(!PollFx.args().contains("--strict-mcp-config"))
    }

    @Test func theModelSchemaAndSystemPromptAreTheGivenOnes() throws {
      let args = PollFx.args()

      #expect(PollFx.value(after: "--model", in: args) == "haiku")
      #expect(PollFx.value(after: "--json-schema", in: args).flatMap { JSON.parse($0) } == PollFx.schema)
      #expect(PollFx.value(after: "--system-prompt", in: args) == PollFx.system)
    }

    @Test func anEmptyDenyListWritesNoDisallowedTools() {
      #expect(!PollFx.args(deny: []).contains("--disallowedTools"))
    }

    @Test func theDenyListGoesToDisallowedTools() {
      let args = PollFx.args(deny: ["mcp__other", PollFx.send])

      #expect(PollFx.disallowed(args) == ["mcp__other", PollFx.send])
    }

    /// D4: the read tool that the profile call learns to deny never reaches the poll's `--disallowedTools`.
    @Test func theDenyListLosesTheCallsOwnToolAndStructuredOutput() {
      let args = PollFx.args(allowed: PollFx.read, deny: [PollFx.read, PollFx.structured, "mcp__other"])

      #expect(PollFx.disallowed(args) == ["mcp__other"])
    }

    @Test func theProfileCallsDenyListLosesTheProfileTool() {
      let args = PollFx.args(allowed: PollFx.profile, deny: [PollFx.profile, PollFx.read])

      #expect(PollFx.disallowed(args) == [PollFx.read])
    }

    @Test func aDenyListOfOnlyTheCallsOwnToolAndStructuredOutputWritesNoFlag() {
      #expect(!PollFx.args(allowed: PollFx.read, deny: [PollFx.read, PollFx.structured]).contains("--disallowedTools"))
    }

    @Test func atMostTwentyThreadsAreReadAtOnce() {
      #expect(SlackPoll.maxThreads == 20)
    }
  }
}

// MARK: - the batch

extension SlackPollTests {
  @Suite struct Batch {
    static let now: Int64 = 1_794_966_000_000

    static func refs(_ count: Int, from start: Int = 0) -> [SlackThreadRef] {
      (start..<start + count).map { i in
        let ts = "1794965\(100 + i).000000"
        return SlackThreadRef(key: "C0EXAMPLE01/\(ts)", channel: "C0EXAMPLE01", thread: ts)
      }
    }

    static func row(_ ref: SlackThreadRef, read: Int64?, tried: Int64?, error: String? = nil) -> SlackThread {
      var row = SlackThread(channel: ref.channel, thread: ref.thread)
      row.read = read
      row.tried = tried
      row.error = error
      return row
    }

    @Test func atMostTwentyThreadsAreInTheBatch() {
      #expect(SlackPoll.batch(Self.refs(25), rows: [:]).count == 20)
    }

    @Test func aThreadNeverAskedForComesBeforeTwentyAskedFor() {
      let asked = Self.refs(20)
      let fresh = Self.refs(1, from: 20)[0]
      let rows = Dictionary(uniqueKeysWithValues: asked.map { ($0.key, Self.row($0, read: Self.now, tried: Self.now)) })

      #expect(SlackPoll.batch(asked + [fresh], rows: rows).contains(fresh))
    }

    /// Twenty threads whose reads always fail have never been read, but they were asked for in the last poll.
    @Test func twentyThreadsThatFailedLastPollDoNotStarveAThreadAskedForLongAgo() {
      let failing = Self.refs(20)
      let old = Self.refs(1, from: 20)[0]
      var rows = Dictionary(
        uniqueKeysWithValues: failing.map { ($0.key, Self.row($0, read: nil, tried: Self.now, error: "denied")) })
      rows[old.key] = Self.row(old, read: Self.now - 3_600_000, tried: Self.now - 3_600_000)

      #expect(SlackPoll.batch(failing + [old], rows: rows).contains(old))
    }

    @Test func theThreadsAskedForLongestAgoComeFirst() {
      let refs = Self.refs(21)
      let rows = Dictionary(
        uniqueKeysWithValues: refs.enumerated().map { i, ref in
          (ref.key, Self.row(ref, read: Self.now, tried: Self.now - Int64(i) * 1000))
        })

      #expect(Set(SlackPoll.batch(refs, rows: rows).map(\.key)) == Set(refs.dropFirst().map(\.key)))
    }
  }
}

// MARK: - the learning order of a fresh sbd

extension SlackPollTests {
  /// D4: on a fresh sbd, claude lists every Slack tool. The profile call is refused at init, sbd learns from it,
  /// and the poll's arguments then don't deny `slack_read_thread`. Each call is refused once and passes on retry.
  @Suite struct LearningOrder {
    @Test func aFreshSbdLearnsTheDenyListAndEachCallPassesOnItsRetry() throws {
      var deny: [String] = []

      let profileFirst = PollFx.args(allowed: PollFx.profile, deny: deny)
      let fromProfile = PollFx.check(tools: PollFx.listed(after: profileFirst), allowed: PollFx.profile)
      #expect(fromProfile == .extra([PollFx.read, PollFx.send]))
      guard case .extra(let profileExtra) = fromProfile else { return }
      deny += SlackPoll.denyEntries(for: Array(profileExtra))

      let profileRetry = PollFx.args(allowed: PollFx.profile, deny: deny)
      #expect(PollFx.check(tools: PollFx.listed(after: profileRetry), allowed: PollFx.profile) == .ok)

      let pollFirst = PollFx.args(allowed: PollFx.read, deny: deny)
      #expect(PollFx.disallowed(pollFirst)?.contains(PollFx.read) != true)
      let fromPoll = PollFx.check(tools: PollFx.listed(after: pollFirst), allowed: PollFx.read)
      #expect(fromPoll == .extra([PollFx.profile]))
      guard case .extra(let pollExtra) = fromPoll else { return }
      deny += SlackPoll.denyEntries(for: Array(pollExtra))

      let pollRetry = PollFx.args(allowed: PollFx.read, deny: deny)
      #expect(PollFx.disallowed(pollRetry) == [PollFx.send, PollFx.profile])
      #expect(PollFx.check(tools: PollFx.listed(after: pollRetry), allowed: PollFx.read) == .ok)
    }

    @Test func aServerAddedLaterIsDeniedByItsPrefixAndThePollPassesOnRetry() {
      let deny = [PollFx.send, PollFx.profile]
      let tools = PollFx.allSlack + ["mcp__late__run", "mcp__late__read"]

      let first = PollFx.check(tools: PollFx.listed(after: PollFx.args(deny: deny), from: tools))
      #expect(first == .extra(["mcp__late__run", "mcp__late__read"]))
      guard case .extra(let extra) = first else { return }
      let retry = PollFx.args(deny: deny + SlackPoll.denyEntries(for: Array(extra)))

      #expect(PollFx.disallowed(retry)?.contains("mcp__late") == true)
      #expect(PollFx.check(tools: PollFx.listed(after: retry, from: tools)) == .ok)
    }
  }
}

// MARK: - initCheck (Risks 1 and 2)

extension SlackPollTests {
  @Suite struct InitCheck {
    @Test func theExactSetPasses() {
      #expect(PollFx.check(tools: PollFx.pollTools) == .ok)
    }

    @Test func aLineThatIsNotAnInitMessageIsRefused() {
      #expect(PollFx.check(PollFx.system("hook_started")).refused)
    }

    @Test func theExactSetInAnotherOrderPasses() {
      #expect(PollFx.check(tools: [PollFx.read, PollFx.structured]) == .ok)
    }

    @Test func theProfileCallsExactSetPasses() {
      #expect(PollFx.check(tools: PollFx.profileTools, allowed: PollFx.profile) == .ok)
    }

    /// Two servers can give one name. A deny entry can't tell them apart, so the check refuses and learns nothing.
    @Test(arguments: [PollFx.read, PollFx.structured])
    func theExactSetWithANameTwiceIsRefused(_ twice: String) {
      #expect(PollFx.check(tools: PollFx.pollTools + [twice]).refused)
    }

    @Test func anExtraMCPToolIsLearned() {
      #expect(PollFx.check(tools: PollFx.pollTools + ["mcp__other__run"]) == .extra(["mcp__other__run"]))
    }

    @Test func anotherSlackToolIsLearned() {
      #expect(PollFx.check(tools: PollFx.pollTools + [PollFx.send]) == .extra([PollFx.send]))
    }

    @Test func anExtraBuiltInToolIsLearned() {
      #expect(PollFx.check(tools: PollFx.pollTools + ["Bash"]) == .extra(["Bash"]))
    }

    @Test func theSetWithoutTheReadToolIsRefused() {
      #expect(PollFx.check(tools: [PollFx.structured]).refused)
    }

    @Test func theSetWithoutStructuredOutputIsRefused() {
      #expect(PollFx.check(tools: [PollFx.read]).refused)
    }

    /// A retry with a longer deny list can't bring back a missing tool.
    @Test func aMissingToolWithAnExtraToolIsRefused() {
      #expect(PollFx.check(tools: [PollFx.structured, "mcp__other__run"]).refused)
    }

    @Test func thePollsToolsAreRefusedForTheProfileCall() {
      #expect(PollFx.check(tools: PollFx.pollTools, allowed: PollFx.profile).refused)
    }

    @Test func anEmptyListIsRefused() {
      #expect(PollFx.check(tools: []).refused)
    }

    @Test func noToolsKeyIsRefused() {
      #expect(PollFx.check(tools: nil).refused)
    }

    @Test(arguments: [JSON.string(PollFx.read), .null, ["name": .string(PollFx.read)]])
    func toolsThatAreNotAListAreRefused(_ tools: JSON) {
      var o = JSON.parse(PollFx.initLine(tools: nil))?.object ?? [:]
      o["tools"] = tools

      #expect(PollFx.check(JSON.object(o).text).refused)
    }

    @Test func aToolThatIsNotAStringIsRefused() {
      var o = JSON.parse(PollFx.initLine(tools: nil))?.object ?? [:]
      o["tools"] = [.string(PollFx.structured), .string(PollFx.read), 42]

      #expect(PollFx.check(JSON.object(o).text).refused)
    }

    // Risk 2

    @Test func noSlackServerIsRefusedAsAnAccountWithoutConnectors() {
      let got = PollFx.check(tools: PollFx.pollTools, servers: [["name": "posthog-db", "status": "connected"]])

      #expect(got.refused)
      #expect(got.reason.contains("doesn't load claude.ai connectors"), "\(got.reason)")
    }

    @Test func noMCPServersKeyIsRefusedAsAnAccountWithoutConnectors() {
      let got = PollFx.check(tools: PollFx.pollTools, servers: nil)

      #expect(got.refused)
      #expect(got.reason.contains("doesn't load claude.ai connectors"), "\(got.reason)")
    }

    @Test func aServerWhoseNameOnlyLooksLikeSlacksIsNotSlack() {
      let got = PollFx.check(
        tools: PollFx.pollTools,
        servers: [["name": "claude.ai Slack2", "status": "connected"], ["name": "Slack", "status": "connected"]])

      #expect(got.refused)
      #expect(got.reason.contains("doesn't load claude.ai connectors"), "\(got.reason)")
    }

    @Test(arguments: ["needs-auth", "failed", "pending"])
    func aSlackServerThatIsNotConnectedIsRefusedWithItsStatus(_ status: String) {
      let got = PollFx.check(tools: PollFx.pollTools, servers: PollFx.servers(status: status))

      #expect(got.refused)
      #expect(got.reason.contains("the claude.ai Slack connector is \(status)"), "\(got.reason)")
    }

    /// A signed-out connector loads no Slack tools. The refusal names the connector's status, not the missing tool.
    @Test func aSignedOutConnectorWithoutItsToolsIsRefusedWithItsStatus() {
      let got = PollFx.check(tools: [PollFx.structured], servers: PollFx.servers(status: "needs-auth"))

      #expect(got.reason.contains("needs-auth"), "\(got.reason)")
    }

    /// Neither Risk 2 refusal retries, so an extra tool does not turn it into a deny entry.
    @Test func aSignedOutConnectorWithAnExtraToolIsRefusedNotLearned() {
      let got = PollFx.check(
        tools: PollFx.pollTools + ["mcp__other__run"], servers: PollFx.servers(status: "needs-auth"))

      #expect(got.refused)
    }
  }
}

// MARK: - lineHandler (Risk 1)

extension SlackPollTests {
  @Suite struct LineHandler {
    static let goodInit = PollFx.initLine(tools: PollFx.pollTools)
    static let call = PollFx.toolUse(
      id: "toolu_A", name: PollFx.read, input: PollFx.readInput(PollFx.chA, PollFx.rootA))
    static let reply = PollFx.toolResult(id: "toolu_A", text: PollFx.threadText(count: 1))
    static let end = PollFx.result(["threads": []])

    @Test func aGoodInitAndTheLinesAfterItPass() {
      let got = PollFx.feed([Self.goodInit, Self.call, Self.reply, PollFx.assistantText("Done."), Self.end])

      #expect(got.refusal == nil)
    }

    @Test func anotherSystemLineBeforeAGoodInitPasses() {
      let got = PollFx.feed([
        PollFx.system("hook_started"), PollFx.system("hook_response"), Self.goodInit, Self.call, Self.end,
      ])

      #expect(got.refusal == nil)
    }

    @Test func noOutputAtAllIsNotRefused() {
      #expect(PollFx.feed([]).refusal == nil)
    }

    @Test func anAssistantLineBeforeInitIsRefused() {
      let got = PollFx.feed([Self.call, Self.goodInit])

      #expect(got.refusal != nil)
      #expect(got.at == 1)
    }

    @Test func anAssistantTextLineBeforeInitIsRefused() {
      #expect(PollFx.feed([PollFx.assistantText("Reading."), Self.goodInit]).at == 1)
    }

    @Test func aUserLineBeforeInitIsRefused() {
      #expect(PollFx.feed([Self.reply, Self.goodInit]).at == 1)
    }

    @Test func aResultLineBeforeInitIsRefused() {
      #expect(PollFx.feed([Self.end, Self.goodInit]).at == 1)
    }

    /// claude prints rate_limit_event lines after init. Only a system line may come before it.
    @Test func aRateLimitEventBeforeInitIsRefused() {
      let rateLimit = JSON.object(["type": "rate_limit_event", "session_id": "0b5f2c4e"]).text

      #expect(PollFx.feed([rateLimit, Self.goodInit]).at == 1)
    }

    @Test func aResultLineWithNoInitIsRefused() {
      #expect(PollFx.feed([PollFx.system("hook_started"), Self.end]).at == 2)
    }

    @Test(arguments: ["not json", "{\"type\":", "[]", "42", "\"init\""])
    func aLineThatIsNotAJSONObjectBeforeInitIsRefused(_ line: String) {
      #expect(PollFx.feed([line, Self.goodInit]).at == 1)
    }

    @Test func aSecondInitAfterAGoodOneIsRefused() {
      let got = PollFx.feed([Self.goodInit, Self.call, PollFx.initLine(tools: PollFx.pollTools + ["mcp__other__run"])])

      #expect(got.at == 3)
    }

    @Test func aSecondGoodInitIsRefusedToo() {
      #expect(PollFx.feed([Self.goodInit, Self.goodInit]).at == 2)
    }

    @Test func aLineThatIsNotJSONAfterAGoodInitPasses() {
      #expect(PollFx.feed([Self.goodInit, "warning: something", Self.end]).refusal == nil)
    }

    @Test func anInitWithAnExtraToolIsRefusedAndTheToolIsRecorded() {
      let got = PollFx.feed([PollFx.initLine(tools: PollFx.pollTools + ["mcp__other__run", PollFx.send]), Self.call])

      #expect(got.at == 1)
      #expect(got.extra == ["mcp__other__run", PollFx.send])
    }

    @Test func anInitWithAMissingToolIsRefusedAndRecordsNoTool() {
      let got = PollFx.feed([PollFx.initLine(tools: [PollFx.structured]), Self.call])

      #expect(got.at == 1)
      #expect(got.extra.isEmpty)
    }

    @Test func anInitWithANameTwiceIsRefused() {
      #expect(PollFx.feed([PollFx.initLine(tools: PollFx.pollTools + [PollFx.read])]).at == 1)
    }

    @Test func anInitOfASignedOutConnectorIsRefusedAndRecordsNoTool() {
      let got = PollFx.feed([
        PollFx.initLine(tools: PollFx.pollTools + [PollFx.send], servers: PollFx.servers(status: "needs-auth"))
      ])

      #expect(got.refusal?.contains("needs-auth") == true, "\(got.refusal ?? "nil")")
      #expect(got.extra.isEmpty)
    }

    @Test func anInitWithoutTheSlackServerIsRefused() {
      let got = PollFx.feed([PollFx.initLine(tools: PollFx.pollTools, servers: [])])

      #expect(got.refusal?.contains("doesn't load claude.ai connectors") == true, "\(got.refusal ?? "nil")")
    }

    @Test func theProfileHandlerChecksTheProfileTools() {
      #expect(PollFx.feed([PollFx.initLine(tools: PollFx.profileTools)], allowed: PollFx.profile).refusal == nil)
      #expect(PollFx.feed([PollFx.initLine(tools: PollFx.pollTools)], allowed: PollFx.profile).at == 1)
    }
  }
}

// MARK: - denyEntries (D4)

extension SlackPollTests {
  @Suite struct DenyEntries {
    @Test func aSlackToolIsDeniedByItsFullName() {
      #expect(SlackPoll.denyEntries(for: [PollFx.send]) == [PollFx.send])
    }

    @Test func anotherServersToolIsDeniedByTheServersPrefix() {
      #expect(SlackPoll.denyEntries(for: ["mcp__posthog-db__execute_sql"]) == ["mcp__posthog-db"])
    }

    @Test func aNameWithoutTheMCPPrefixIsDeniedByItsFullName() {
      #expect(SlackPoll.denyEntries(for: ["Bash"]) == ["Bash"])
    }

    /// A server whose name starts with the Slack server's name is another server.
    @Test func aServerWhoseNameStartsWithTheSlackServersIsDeniedByItsOwnPrefix() {
      #expect(SlackPoll.denyEntries(for: ["mcp__claude_ai_Slack_evil__run"]) == ["mcp__claude_ai_Slack_evil"])
    }

    @Test func aServerWhoseNameIsTheSlackServersPlusOneCharacterIsDeniedByItsOwnPrefix() {
      #expect(SlackPoll.denyEntries(for: ["mcp__claude_ai_Slack_x__run"]) == ["mcp__claude_ai_Slack_x"])
    }

    @Test func twoToolsOfOneServerDenyThatServer() {
      #expect(Set(SlackPoll.denyEntries(for: ["mcp__other__a", "mcp__other__b"])) == ["mcp__other"])
    }

    @Test func aMixOfNamesGivesEachItsEntry() {
      let got = Set(SlackPoll.denyEntries(for: [PollFx.send, "mcp__other__run", "Bash"]))

      #expect(got == [PollFx.send, "mcp__other", "Bash"])
    }

    /// Denying the prefix would deny the call's own tool.
    @Test(arguments: [
      "mcp__claude_ai_Slack", "mcp__claude_ai_Slack__", "mcp__claude_ai_Slack__slack_send_message",
      "mcp__claude_ai_Slack__slack_read_thread",
    ])
    func noEntryIsEverTheSlackServersPrefix(_ name: String) {
      #expect(!SlackPoll.denyEntries(for: [name]).contains("mcp__claude_ai_Slack"))
    }
  }
}

// MARK: - inputs

extension SlackPollTests {
  @Suite struct Inputs {
    /// The JSON list between the tags.
    func asked(_ input: String) throws -> [JSON] {
      #expect(input.hasPrefix("<slack-threads>"))
      #expect(input.hasSuffix("</slack-threads>"))
      let inner = input.dropFirst("<slack-threads>".count).dropLast("</slack-threads>".count)
      return try #require(JSON.parse(String(inner))?.array)
    }

    @Test func theThreadsInputListsEachAskWithOldestOnlyWhenGiven() throws {
      let input = SlackPoll.threadsInput([
        PollFx.askA, SlackPoll.Ask(channel: PollFx.chB, thread: PollFx.rootB, oldest: PollFx.reply1),
      ])

      let list = try asked(input)

      #expect(
        list == [
          ["channel_id": .string(PollFx.chA), "message_ts": .string(PollFx.rootA)],
          ["channel_id": .string(PollFx.chB), "message_ts": .string(PollFx.rootB), "oldest": .string(PollFx.reply1)],
        ])
    }

    @Test func theSelfInputIsTagged() {
      #expect(SlackPoll.selfInput.hasPrefix("<slack-self>"))
      #expect(SlackPoll.selfInput.hasSuffix("</slack-self>"))
    }
  }
}

// MARK: - parseThreads (Risk 3)

extension SlackPollTests {
  @Suite struct ParseThreadsReads {
    @Test func twoGoodThreadsAreBothRead() throws {
      let got = try PollFx.outcomes(
        PollFx.stream([PollFx.goodA(), PollFx.goodB()]), asked: [PollFx.askA, PollFx.askB])

      #expect(got == [PollFx.keyA: .read(PollFx.readA), PollFx.keyB: .read(PollFx.readA)])
    }

    @Test func aResultWhoseContentIsAPlainStringIsRead() throws {
      var b = PollFx.goodB()
      b.plainResult = true

      #expect(try PollFx.outcomeOfB(b) == .read(PollFx.readA))
    }

    @Test func aThreadWithNoRepliesIsReadWithNoLastReply() throws {
      #expect(try PollFx.outcomeOfB(PollFx.Part(PollFx.askB, id: "toolu_B", count: 0)) == .read(PollFx.Read(count: 0)))
    }

    @Test func aCallWithTheAskedOldestIsRead() throws {
      let ask = SlackPoll.Ask(channel: PollFx.chB, thread: PollFx.rootB, oldest: PollFx.reply1)

      let got = try PollFx.outcomeOfB(PollFx.Part(ask, id: "toolu_B", last: PollFx.reply2), ask: ask)

      #expect(got == .read(PollFx.Read(count: 1, ts: PollFx.reply2, user: PollFx.other, name: "Alice")))
    }

    @Test func aCountOfTenThousandIsRead() throws {
      #expect(try PollFx.outcomeOfB(PollFx.Part(PollFx.askB, id: "toolu_B", count: 10000)).read?.count == 10000)
    }

    @Test func anAnswerWithoutANameIsReadWithoutOne() throws {
      let got = try PollFx.outcomeOfB(PollFx.Part(PollFx.askB, id: "toolu_B", name: nil))

      #expect(got == .read(PollFx.Read(count: 1, ts: PollFx.reply1, user: PollFx.other, name: nil)))
    }

    /// One matching call is enough, whatever the other calls for the thread did.
    @Test func anErrorCallThenAMatchingCallIsRead() throws {
      var failed = PollFx.goodB()
      failed.id = "toolu_B0"
      failed.resultError = true
      failed.resultText = "rate limited"
      failed.answer = nil

      #expect(try PollFx.outcomeOfB(failed, PollFx.goodB()) == .read(PollFx.readA))
    }

    @Test func aMatchingCallThenACallForAnotherTsIsRead() throws {
      var stray = PollFx.goodB()
      stray.id = "toolu_B9"
      stray.input = PollFx.readInput(PollFx.chB, "1794965999.000001")
      stray.answer = nil

      #expect(try PollFx.outcomeOfB(PollFx.goodB(), stray) == .read(PollFx.readA))
    }

    /// Only the answer's name has the new lines, because they would split the connector's `From:` line.
    @Test func aNameWithNewLinesIsOneLine() throws {
      var b = PollFx.goodB()
      b.setAnswer("last_reply_user_name", "Al\nice\r\nSmith")
      let got = try PollFx.outcomeOfB(b)

      let name = try #require(got.read?.name)
      #expect(!name.contains { $0.isNewline }, "\(name.debugDescription)")
    }

    @Test func aLongNameIsCutToEightyCharacters() throws {
      let got = try PollFx.outcomeOfB(
        PollFx.Part(PollFx.askB, id: "toolu_B", name: String(repeating: "a", count: 10_000)))

      let name = try #require(got.read?.name)
      #expect(name.count <= 80)
      #expect(name.hasPrefix("aaaa"))
    }
  }

  /// Check 1: a `slack_read_thread` tool_use for exactly the asked channel, ts, and oldest.
  @Suite struct ParseThreadsCall {
    @Test func noCallForTheThreadFails() throws {
      var b = PollFx.goodB()
      b.hasCall = false

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    /// With no replies, no user id needs the result text, so only the call check refuses the thread.
    @Test func noCallForAThreadWithNoRepliesFails() throws {
      var b = PollFx.Part(PollFx.askB, id: "toolu_B", count: 0)
      b.hasCall = false

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aCallForAnotherChannelFails() throws {
      var b = PollFx.goodB()
      b.input = PollFx.readInput("C0EXAMPLE09", PollFx.rootB)

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aCallForAnotherTsFails() throws {
      var b = PollFx.goodB()
      b.input = PollFx.readInput(PollFx.chB, "1794965100.000201")

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aCallWithoutTheAskedOldestFails() throws {
      let ask = SlackPoll.Ask(channel: PollFx.chB, thread: PollFx.rootB, oldest: PollFx.reply1)
      var b = PollFx.Part(ask, id: "toolu_B", last: PollFx.reply2)
      b.input = PollFx.readInput(PollFx.chB, PollFx.rootB)

      #expect(try PollFx.outcomeOfB(b, ask: ask).failed)
    }

    @Test func aCallWithAnEarlierOldestFails() throws {
      let ask = SlackPoll.Ask(channel: PollFx.chB, thread: PollFx.rootB, oldest: PollFx.reply1)
      var b = PollFx.Part(ask, id: "toolu_B", last: PollFx.reply2)
      b.input = PollFx.readInput(PollFx.chB, PollFx.rootB, oldest: PollFx.rootB)

      #expect(try PollFx.outcomeOfB(b, ask: ask).failed)
    }

    /// A later oldest drops replies from the count, so the stored count would be short.
    @Test func aCallWithALaterOldestFails() throws {
      let ask = SlackPoll.Ask(channel: PollFx.chB, thread: PollFx.rootB, oldest: PollFx.reply1)
      var b = PollFx.Part(ask, id: "toolu_B", last: PollFx.reply2)
      b.input = PollFx.readInput(PollFx.chB, PollFx.rootB, oldest: "1794965250.000000")

      #expect(try PollFx.outcomeOfB(b, ask: ask).failed)
    }

    @Test(arguments: [JSON.null, 1794965100.0002, ""])
    func aCallWithAnOldestThatIsNotATsWhenNoneWasAskedFails(_ oldest: JSON) throws {
      var b = PollFx.goodB()
      var input = PollFx.readInput(PollFx.chB, PollFx.rootB).object ?? [:]
      input["oldest"] = oldest
      b.input = .object(input)

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aCallWithAnOldestWhenNoneWasAskedFails() throws {
      var b = PollFx.goodB()
      b.input = PollFx.readInput(PollFx.chB, PollFx.rootB, oldest: PollFx.rootB)

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test(arguments: [
      "mcp__claude_ai_Slack__slack_read_channel", "mcp__claude_ai_Slack_evil__slack_read_thread", "slack_read_thread",
    ])
    func aCallToAnotherToolFails(_ tool: String) throws {
      var b = PollFx.goodB()
      b.tool = tool

      #expect(try PollFx.outcomeOfB(b).failed)
    }
  }

  /// Check 2: a tool_result for that call that isn't an error.
  @Suite struct ParseThreadsResult {
    @Test func anErrorResultFails() throws {
      var b = PollFx.goodB()
      b.resultError = true

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func noResultFails() throws {
      var b = PollFx.goodB()
      b.hasResult = false

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    /// With no replies, no user id needs the result text, so only the result check refuses the thread.
    @Test func noResultForAThreadWithNoRepliesFails() throws {
      var b = PollFx.Part(PollFx.askB, id: "toolu_B", count: 0)
      b.hasResult = false

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aResultForAnotherCallFails() throws {
      var b = PollFx.goodB()
      b.resultId = "toolu_other"

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    /// One page of a longer thread would give a short count.
    @Test func aResultWithMoreMessagesLeftFails() throws {
      var b = PollFx.goodB()
      b.resultText = PollFx.threadText(
        count: 1, pages: "There are more messages in this thread. Use the cursor dGVz.\n")

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aResultWithoutPaginationInfoFails() throws {
      var b = PollFx.goodB()
      b.resultText = PollFx.threadText(count: 1, pages: nil)

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aResultThatIsNotTheConnectorsObjectFails() throws {
      var b = PollFx.goodB()
      b.resultText = "From: Alice (U0OTHER)\nMessage TS: \(PollFx.reply1)\nLooks good to me."

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aResultForAnotherCallOfAThreadWithNoRepliesFails() throws {
      var b = PollFx.Part(PollFx.askB, id: "toolu_B", count: 0)
      b.resultId = "toolu_other"

      #expect(try PollFx.outcomeOfB(b).failed)
    }
  }

  /// Check 3: the answer has `ok: true` and a whole `reply_count` from 0 to 10000.
  @Suite struct ParseThreadsAnswer {
    @Test func okFalseFails() throws {
      var b = PollFx.goodB()
      b.setAnswer("ok", false)
      b.setAnswer("error", "channel_not_found")

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func noOkFails() throws {
      var b = PollFx.goodB()
      b.setAnswer("ok", nil)

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func noAnswerForAnAskedThreadFails() throws {
      var b = PollFx.goodB()
      b.answer = nil

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aNegativeCountFails() throws {
      var b = PollFx.goodB()
      b.setAnswer("reply_count", -1)

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aCountOverTenThousandFails() throws {
      var b = PollFx.goodB()
      b.setAnswer("reply_count", 10001)

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aFractionalCountFails() throws {
      var b = PollFx.goodB()
      b.setAnswer("reply_count", 1.5)

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aCountGivenAsTextFails() throws {
      var b = PollFx.goodB()
      b.setAnswer("reply_count", "1")

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    /// sbd can't tell which of two answers for one thread is right.
    @Test func twoAnswersForOneThreadFail() throws {
      let b = PollFx.goodB()
      let second = PollFx.answer(
        PollFx.chB, PollFx.rootB, count: 2, last: PollFx.reply1, user: PollFx.other, name: "Alice")

      #expect(try PollFx.outcomeOfB(b, extraAnswers: [second]).failed)
    }

    @Test func anAnswerForAThreadThatWasNotAskedIsDropped() throws {
      let stray = PollFx.answer(
        "C0EXAMPLE09", "1794965900.000900", count: 1, last: PollFx.reply1, user: PollFx.other, name: "Eve")

      let got = try PollFx.outcomes(PollFx.stream([PollFx.goodA()], extraAnswers: [stray]), asked: [PollFx.askA])

      #expect(got == [PollFx.keyA: .read(PollFx.readA)])
    }

    @Test func anAnswerForAThreadThatWasNotAskedIsDroppedEvenWithItsOwnCall() throws {
      let strayAsk = SlackPoll.Ask(channel: "C0EXAMPLE09", thread: "1794965900.000900", oldest: nil)

      let got = try PollFx.outcomes(
        PollFx.stream([PollFx.goodA(), PollFx.Part(strayAsk, id: "toolu_S")]), asked: [PollFx.askA])

      #expect(got == [PollFx.keyA: .read(PollFx.readA)])
    }
  }

  /// Check 4: with replies, a well-formed `last_reply_ts` after the root and the oldest, and a Slack user id that
  /// appears as a whole word in the matching call's result.
  @Suite struct ParseThreadsLastReply {
    @Test(arguments: ["1794965246.46", "1794965246", "17949652460.462679", "1794965246.4626790", "soon", ""])
    func aMalformedLastReplyTsFails(_ ts: String) throws {
      var b = PollFx.goodB()
      b.setAnswer("last_reply_ts", .string(ts))

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aLastReplyTsAtTheRootFails() throws {
      var b = PollFx.goodB()
      b.setAnswer("last_reply_ts", .string(PollFx.rootB))

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aLastReplyTsBeforeTheRootFails() throws {
      var b = PollFx.goodB()
      b.setAnswer("last_reply_ts", "1794965100.000199")

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aLastReplyTsAtTheOldestFails() throws {
      let ask = SlackPoll.Ask(channel: PollFx.chB, thread: PollFx.rootB, oldest: PollFx.reply1)

      let got = try PollFx.outcomeOfB(PollFx.Part(ask, id: "toolu_B", last: PollFx.reply1), ask: ask)

      #expect(got.failed)
    }

    @Test func aLastReplyTsBetweenTheRootAndTheOldestFails() throws {
      let ask = SlackPoll.Ask(channel: PollFx.chB, thread: PollFx.rootB, oldest: PollFx.reply1)

      let got = try PollFx.outcomeOfB(PollFx.Part(ask, id: "toolu_B", last: "1794965200.000000"), ask: ask)

      #expect(got.failed)
    }

    @Test func noLastReplyTsWithRepliesFails() throws {
      #expect(try PollFx.outcomeOfB(PollFx.Part(PollFx.askB, id: "toolu_B", last: nil)).failed)
    }

    @Test func noUserIdWithRepliesFails() throws {
      var b = PollFx.goodB()
      b.setAnswer("last_reply_user_id", nil)

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aUserIdThatIsNotInTheResultFails() throws {
      var b = PollFx.goodB()
      b.resultText = PollFx.threadText(count: 1, user: "U0CAROL", name: "Carol")

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    /// The text holds a longer id that contains the answer's id.
    @Test(arguments: ["U0OTHER2", "XU0OTHER", "U0OTHER_BOT"])
    func aUserIdThatOnlyAppearsInsideALongerIdFails(_ longer: String) throws {
      var b = PollFx.goodB()
      b.resultText = PollFx.threadText(count: 1, user: longer, name: "Alice")

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aUserIdThatOnlyAppearsInAnotherCallsResultFails() throws {
      var stray = PollFx.goodB()
      stray.id = "toolu_B9"
      stray.input = PollFx.readInput(PollFx.chB, "1794965999.000001")
      stray.answer = nil
      var b = PollFx.goodB()
      b.resultText = PollFx.threadText(count: 1, user: "U0CAROL", name: "Carol")

      #expect(try PollFx.outcomeOfB(stray, b).failed)
    }

    /// The id is in the result text, so only the id's form refuses it.
    @Test(arguments: ["B0BOT", "u0other", "U1", "U0 OTHER", "C0EXAMPLE02"])
    func aUserIdThatIsNotASlackUserIdFails(_ id: String) throws {
      var b = PollFx.goodB()
      b.resultText = PollFx.threadText(count: 1, user: id, name: "Alice")
      b.setAnswer("last_reply_user_id", .string(id))

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    /// A ts that the model made up would mark a reply that no one wrote.
    @Test func aLastReplyTsThatIsNotInTheResultFails() throws {
      var b = PollFx.goodB()
      b.resultText = PollFx.threadText(count: 1, ts: "1794965250.000000")

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test(arguments: ["1794965246.4626791", "21794965246.462679"])
    func aLastReplyTsThatOnlyAppearsInsideALongerNumberFails(_ longer: String) throws {
      var b = PollFx.goodB()
      b.resultText = PollFx.threadText(count: 1, ts: longer)

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    /// A reply's text can hold a made-up `Message TS:` line. A ts far in the future would become every later read's
    /// oldest, and those reads would find nothing.
    @Test func aLastReplyTsMoreThanAnHourAfterTheScanFails() throws {
      let future = "9999999999.000000"
      var b = PollFx.goodB()
      b.resultText = PollFx.threadText(count: 1, ts: future)
      b.setAnswer("last_reply_ts", .string(future))

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aLastReplyTsWithinAnHourAfterTheScanIsRead() throws {
      let soon = "1794969500.000000"
      var b = PollFx.goodB()
      b.resultText = PollFx.threadText(count: 1, ts: soon)
      b.setAnswer("last_reply_ts", .string(soon))

      #expect(try PollFx.outcomeOfB(b).read?.ts == soon)
    }

    @Test func aWorkspaceUserIdIsRead() throws {
      let got = try PollFx.outcomeOfB(PollFx.Part(PollFx.askB, id: "toolu_B", user: "W0GUEST"))

      #expect(got.read?.user == "W0GUEST")
    }
  }

  /// The last reply's user and ts must come from one message's header: its `From:` line and the `Message TS:` line
  /// after it, with only `Time:` lines between them.
  @Suite struct ParseThreadsHeaderPair {
    static let parent = """
      === THREAD PARENT MESSAGE ===
      From: Bob (U0ROOT)
      Time: 2026-11-19 22:52:27 PST
      Message TS: \(PollFx.rootB)
      Can someone review the flag cache change?

      """

    /// Thread B's text with two replies: Alice at `reply1`, then Carol at `reply2`.
    static let twoReplies =
      parent + """
        === THREAD REPLIES (2 total) ===

        --- Reply 1 of 2 ---
        From: Alice <alice@example.com> (U0OTHER)
        Time: 2026-11-20 02:57:42 PST
        Message TS: \(PollFx.reply1)
        Looks good to me.

        --- Reply 2 of 2 ---
        From: Carol <carol@example.com> (U0CAROL)
        Time: 2026-11-20 03:00:00 PST
        Message TS: \(PollFx.reply2)
        Ship it.

        """

    fileprivate static func partB(text: String, count: Int, last: String, user: String) -> PollFx.Part {
      var b = PollFx.Part(PollFx.askB, id: "toolu_B", count: count, last: last, user: user)
      b.resultText = PollFx.connectorText(text)
      return b
    }

    @Test func theNewestRepliesUserAndTsFromOneHeaderAreRead() throws {
      let got = try PollFx.outcomeOfB(Self.partB(text: Self.twoReplies, count: 2, last: PollFx.reply2, user: "U0CAROL"))

      #expect(got.read?.count == 2)
      #expect(got.read?.user == "U0CAROL")
    }

    /// The stub's header has no `Time:` line.
    @Test func aHeaderWithoutATimeLineIsRead() throws {
      let text = Self.parent + "From: Alice (U0OTHER)\nMessage TS: \(PollFx.reply1)\nLooks good to me.\n"

      #expect(
        try PollFx.outcomeOfB(Self.partB(text: text, count: 1, last: PollFx.reply1, user: PollFx.other)).read != nil)
    }

    /// A mention puts the user's id in the text, but the reply is Carol's.
    @Test func aUserWhoIsOnlyMentionedInTheReplyFails() throws {
      var b = PollFx.goodB()
      b.resultText = PollFx.threadText(count: 1, user: "U0CAROL", name: "Carol", body: "<@U0OTHER|alice> looks good.")

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func oneRepliesUserWithAnotherRepliesTsFails() throws {
      let b = Self.partB(text: Self.twoReplies, count: 2, last: PollFx.reply2, user: PollFx.other)

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    /// The display name holds `(U0OTHER)`, but the line's own id is U0EVE.
    @Test func aUserIdInsideTheDisplayNameFails() throws {
      let text =
        Self.parent + "From: Eve (U0OTHER) <eve@example.com> (U0EVE)\nMessage TS: \(PollFx.reply1)\nHello.\n"

      #expect(try PollFx.outcomeOfB(Self.partB(text: text, count: 1, last: PollFx.reply1, user: PollFx.other)).failed)
    }

    /// The parent's text ends with a `From:` line, and Carol's real header follows the reply heading.
    @Test func aFromLineInAMessagesTextDoesNotPairWithTheNextHeadersTs() throws {
      let text = """
        === THREAD PARENT MESSAGE ===
        From: Bob (U0ROOT)
        Message TS: \(PollFx.rootB)
        Please review.
        From: Alice (U0OTHER)
        === THREAD REPLIES (1 total) ===
        From: Carol (U0CAROL)
        Message TS: \(PollFx.reply1)
        Done.

        """

      #expect(try PollFx.outcomeOfB(Self.partB(text: text, count: 1, last: PollFx.reply1, user: PollFx.other)).failed)
    }

    @Test func aLineOtherThanTimeBetweenTheFromAndTsLinesFails() throws {
      let text =
        Self.parent + "From: Alice (U0OTHER)\nLooks good.\nMessage TS: \(PollFx.reply1)\n"

      #expect(try PollFx.outcomeOfB(Self.partB(text: text, count: 1, last: PollFx.reply1, user: PollFx.other)).failed)
    }
  }

  /// A count of 0 needs a read that shows no replies: no `=== THREAD REPLIES` line, or one that says `(0 total)`.
  @Suite struct ParseThreadsZeroCount {
    static let askBOldest = SlackPoll.Ask(channel: PollFx.chB, thread: PollFx.rootB, oldest: PollFx.reply1)

    fileprivate static func zeroAnswer(_ b: inout PollFx.Part) {
      b.answer = PollFx.answer(b.ask.channel, b.ask.thread, count: 0, last: nil, user: nil, name: nil)
    }

    @Test func aZeroCountWhenTheReadShowsAReplyFails() throws {
      var b = PollFx.goodB()
      Self.zeroAnswer(&b)

      #expect(try PollFx.outcomeOfB(b).failed)
    }

    @Test func aZeroCountWithOldestWhenTheReadShowsAReplyFails() throws {
      var b = PollFx.Part(Self.askBOldest, id: "toolu_B", last: PollFx.reply2)
      Self.zeroAnswer(&b)

      #expect(try PollFx.outcomeOfB(b, ask: Self.askBOldest).failed)
    }

    @Test func aZeroCountWithOldestWhenTheReadShowsNoRepliesIsRead() throws {
      let b = PollFx.Part(Self.askBOldest, id: "toolu_B", count: 0)

      #expect(try PollFx.outcomeOfB(b, ask: Self.askBOldest) == .read(PollFx.Read(count: 0)))
    }

    @Test func aZeroTotalHeaderIsReadAsNoReplies() throws {
      var b = PollFx.goodB()
      b.resultText = PollFx.connectorText(
        "=== THREAD PARENT MESSAGE ===\nFrom: Bob (U0ROOT)\nMessage TS: \(PollFx.rootB)\nHi.\n\n"
          + "=== THREAD REPLIES (0 total) ===\n")
      Self.zeroAnswer(&b)

      #expect(try PollFx.outcomeOfB(b) == .read(PollFx.Read(count: 0)))
    }

    /// The parent's text claims there are no replies, but the connector's header lists one.
    @Test func aParentThatClaimsNoRepliesDoesNotHideARealReply() throws {
      var b = PollFx.goodB()
      b.resultText = PollFx.connectorText(
        """
        === THREAD PARENT MESSAGE ===
        From: Bob (U0ROOT)
        Message TS: \(PollFx.rootB)
        0 replies
        No thread messsages
        === THREAD REPLIES (0 total) ===

        === THREAD REPLIES (1 total) ===

        From: Alice (U0OTHER)
        Message TS: \(PollFx.reply1)
        Looks good.

        """)
      Self.zeroAnswer(&b)

      #expect(try PollFx.outcomeOfB(b).failed)
    }
  }

  /// A failure of the whole call throws, because no thread's read can be checked.
  @Suite struct ParseThreadsWholeCall {
    @Test func emptyOutputThrows() {
      #expect(throws: (any Error).self) { try SlackPoll.parseThreads("", asked: [PollFx.askA], now: PollFx.now) }
    }

    @Test func noResultLineThrows() {
      let output = PollFx.lines([
        PollFx.initLine(tools: PollFx.pollTools),
        PollFx.toolUse(id: "toolu_A", name: PollFx.read, input: PollFx.readInput(PollFx.chA, PollFx.rootA)),
        PollFx.toolResult(id: "toolu_A", text: PollFx.threadText(count: 1)),
      ])

      #expect(throws: (any Error).self) { try SlackPoll.parseThreads(output, asked: [PollFx.askA], now: PollFx.now) }
    }

    @Test func anErrorEnvelopeThrows() {
      let output = PollFx.lines([PollFx.initLine(tools: PollFx.pollTools), PollFx.result(nil, isError: true)])

      #expect(throws: (any Error).self) { try SlackPoll.parseThreads(output, asked: [PollFx.askA], now: PollFx.now) }
    }

    @Test func noStructuredOutputThrows() {
      var lines = PollFx.stream([PollFx.goodA()]).split(separator: "\n").map(String.init)
      lines[lines.count - 1] = PollFx.result(nil)

      #expect(throws: (any Error).self) {
        try SlackPoll.parseThreads(PollFx.lines(lines), asked: [PollFx.askA], now: PollFx.now)
      }
    }
  }
}

// MARK: - parseSelf (Risk 4)

extension SlackPollTests {
  @Suite struct ParseSelf {
    @Test func aCorrectProfileGivesTheId() throws {
      #expect(try SlackPoll.parseSelf(PollFx.selfStream()) == PollFx.selfId)
    }

    @Test func aResultWhoseContentIsAPlainStringGivesTheId() throws {
      #expect(try SlackPoll.parseSelf(PollFx.selfStream(plain: true)) == PollFx.selfId)
    }

    @Test func anEmptyUserIdInTheInputGivesTheId() throws {
      #expect(try SlackPoll.parseSelf(PollFx.selfStream(input: ["user_id": ""])) == PollFx.selfId)
    }

    /// With a `user_id`, the profile is another user's.
    @Test func aUserIdInTheInputThrows() {
      let output = PollFx.selfStream(
        input: ["user_id": "U0SOMEONE"], text: "Name: Someone\nUser ID: U0SOMEONE", structured: ["user_id": "U0SOMEONE"]
      )

      #expect(throws: (any Error).self) { try SlackPoll.parseSelf(output) }
    }

    @Test func noToolCallThrows() {
      #expect(throws: (any Error).self) { try SlackPoll.parseSelf(PollFx.selfStream(hasCall: false)) }
    }

    @Test func aCallToAnotherToolThrows() {
      #expect(throws: (any Error).self) { try SlackPoll.parseSelf(PollFx.selfStream(tool: PollFx.read)) }
    }

    @Test func noResultThrows() {
      #expect(throws: (any Error).self) { try SlackPoll.parseSelf(PollFx.selfStream(hasResult: false)) }
    }

    @Test func anErrorResultThrows() {
      #expect(throws: (any Error).self) { try SlackPoll.parseSelf(PollFx.selfStream(resultError: true)) }
    }

    @Test func aResultForAnotherCallThrows() {
      #expect(throws: (any Error).self) { try SlackPoll.parseSelf(PollFx.selfStream(resultId: "toolu_other")) }
    }

    @Test func aResultWithoutAUserIdLineThrows() {
      #expect(throws: (any Error).self) {
        try SlackPoll.parseSelf(PollFx.selfStream(text: "Name: You\nTitle: Engineer \(PollFx.selfId)"))
      }
    }

    @Test func aStructuredIdThatDiffersFromTheTextThrows() {
      #expect(throws: (any Error).self) {
        try SlackPoll.parseSelf(PollFx.selfStream(structured: ["user_id": "U0MADEUP"]))
      }
    }

    /// The text names a longer id that starts with the structured one.
    @Test func aStructuredIdThatIsOnlyAPrefixOfTheTextsIdThrows() {
      #expect(throws: (any Error).self) {
        try SlackPoll.parseSelf(PollFx.selfStream(text: "Name: You\nUser ID: \(PollFx.selfId)2"))
      }
    }

    @Test func noStructuredOutputThrows() {
      #expect(throws: (any Error).self) { try SlackPoll.parseSelf(PollFx.selfStream(structured: nil)) }
    }

    @Test func aUserIdLineWithoutASlackUserIdThrows() {
      #expect(throws: (any Error).self) {
        try SlackPoll.parseSelf(PollFx.selfStream(text: "User ID: bob", structured: ["user_id": "bob"]))
      }
    }

    /// Two profile reads that disagree leave no one id to trust.
    @Test func twoProfileReadsWithDifferentIdsThrow() {
      let result = { (id: String) in JSON.object(["result": .string("User ID: \(id)")]).text }
      let output = PollFx.lines([
        PollFx.initLine(tools: PollFx.profileTools),
        PollFx.toolUse(id: "toolu_P1", name: PollFx.profile, input: [:]),
        PollFx.toolResult(id: "toolu_P1", text: result(PollFx.selfId)),
        PollFx.toolUse(id: "toolu_P2", name: PollFx.profile, input: [:]),
        PollFx.toolResult(id: "toolu_P2", text: result("U0SOMEONE")),
        PollFx.result(["user_id": .string(PollFx.selfId)]),
      ])

      #expect(throws: (any Error).self) { try SlackPoll.parseSelf(output) }
    }

    @Test func noResultLineThrows() {
      #expect(throws: (any Error).self) { try SlackPoll.parseSelf(PollFx.selfStream(hasEnvelope: false)) }
    }

    @Test func anErrorEnvelopeThrows() {
      #expect(throws: (any Error).self) { try SlackPoll.parseSelf(PollFx.selfStream(envelopeError: true)) }
    }

    @Test func emptyOutputThrows() {
      #expect(throws: (any Error).self) { try SlackPoll.parseSelf("") }
    }
  }
}
