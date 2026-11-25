import Foundation

/// How sbd reads Slack threads.
public struct SlackSettings: Codable, Equatable, Sendable {
  /// How often sbd looks for watched threads and reads them, on sbd's clock. 0 turns the poll off.
  public var pollSeconds: Double = 1200
  /// The model of the poll and the profile call.
  public var model: String = "haiku"
  /// The longest `pollSeconds`, the length of a thread's watch. A longer interval could let a whole watch pass with
  /// no read.
  public static let maxPollSeconds = Double(SlackWatch.windowMs / 1000)

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = SlackSettings()
    pollSeconds = try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? d.pollSeconds
    // sbd turns the value into whole milliseconds, which stops the process for a value that is not finite or is
    // past Int64's range.
    if !pollSeconds.isFinite || pollSeconds > Self.maxPollSeconds {
      logLine("skipping slack.pollSeconds: its value must be a number of seconds up to \(Int(Self.maxPollSeconds))")
      pollSeconds = d.pollSeconds
    }
    model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
  }
}

/// The headless `claude -p` calls that read Slack threads through the claude.ai Slack connector, and the checks on
/// what they print. Thread text is untrusted, and the call loads the user's own settings, so each call must expose
/// exactly its one Slack tool before the model's first turn, and each answer must match a tool result in the stream.
public enum SlackPoll {
  public static let server = "claude.ai Slack"
  public static let readTool = "mcp__claude_ai_Slack__slack_read_thread"
  public static let profileTool = "mcp__claude_ai_Slack__slack_read_user_profile"
  static let structuredTool = "StructuredOutput"
  static let slackPrefix = "mcp__claude_ai_Slack"
  /// The most threads that one poll reads.
  public static let maxThreads = 20

  /// The threads that one poll reads: up to `maxThreads`, the ones whose keys `first` holds first, then the ones
  /// never asked for, and then the ones asked for longest ago. Threads in the same place keep the order of `refs`.
  /// A failed read counts as asked, so threads whose reads always fail can't take every slot.
  public static func batch(_ refs: [SlackThreadRef], rows: [String: SlackThread], first: Set<String> = [])
    -> [SlackThreadRef]
  {
    let order = refs.enumerated().map { i, ref in
      (ref: ref, place: (first.contains(ref.key) ? 0 : 1, rows[ref.key]?.tried ?? -1, i))
    }
    return Array(order.sorted { $0.place < $1.place }.map(\.ref).prefix(maxThreads))
  }

  /// The settings that override what `--setting-sources user` loads: no hooks, no memory, no CLAUDE.md, and no
  /// advisor, which `--disallowedTools` can't remove.
  static let settings =
    #"{"disableAllHooks":true,"autoMemoryEnabled":false,"claudeMdExcludes":["/Users/**"],"advisorModel":""}"#

  /// The arguments of a call whose one tool is `allowed`. `--setting-sources user` and the lack of
  /// `--strict-mcp-config` load the claude.ai connectors. The deny list loses `allowed` and `StructuredOutput`,
  /// because one call learns to deny the other call's tool.
  public static func arguments(model: String, schema: JSON, system: String, allowed: String, deny: [String])
    -> [String]
  {
    let denied = deny.filter { $0 != allowed && $0 != structuredTool }
    var args = [
      "-p", "--model", model, "--output-format", "stream-json", "--verbose", "--json-schema", schema.text, "--tools",
      "", "--setting-sources", "user", "--settings", settings, "--permission-mode", "dontAsk", "--allowedTools",
      allowed,
    ]
    // The flag takes every value up to the next flag, so the flags after it end the list.
    if !denied.isEmpty { args += ["--disallowedTools"] + denied }
    return args + ["--no-session-persistence", "--disable-slash-commands", "--system-prompt", system]
  }

  // MARK: Inputs

  /// A thread that a poll reads, with the `oldest` that limits the read to newer messages.
  public struct Ask: Equatable, Sendable {
    public var channel: String
    public var thread: String
    public var oldest: String?

    public init(channel: String, thread: String, oldest: String?) {
      self.channel = channel
      self.thread = thread
      self.oldest = oldest
    }

    /// The whole input of the read. A read with any other input doesn't count. A cursor or a response format would
    /// page or trim the result, so the read would not hold the whole thread.
    public var input: [String: JSON] {
      var o: [String: JSON] = ["channel_id": .string(channel), "message_ts": .string(thread)]
      if let oldest { o["oldest"] = .string(oldest) }
      return o
    }
  }

  public static func threadsInput(_ asks: [Ask]) -> String {
    "<slack-threads>\(JSON.array(asks.map { .object($0.input) }).text)</slack-threads>"
  }

  public static let selfInput = "<slack-self>Read my own Slack profile and give my user id.</slack-self>"

  public static var threadsSystem: String { Prompts.text(.slackThreads) }

  public static let threadsSchema: JSON = [
    "type": "object", "required": ["threads"], "additionalProperties": false,
    "properties": [
      "threads": [
        "type": "array",
        "items": [
          "type": "object", "required": ["channel_id", "message_ts", "ok", "reply_count"],
          "additionalProperties": false,
          "properties": [
            "channel_id": ["type": "string", "description": "The input's channel_id, copied exactly."],
            "message_ts": ["type": "string", "description": "The input's message_ts, copied exactly."],
            "ok": ["type": "boolean", "description": "False when the read failed."],
            "error": ["type": "string", "description": "The read's error text. Only when ok is false."],
            "reply_count": [
              "type": "integer",
              "description": "Replies after the thread's first message. 0 when none or when ok is false.",
            ],
            "last_reply_ts": [
              "type": "string", "pattern": #"^[0-9]{10}\.[0-9]{6}$"#,
              "description": "The Message TS value of the reply with the greatest ts, copied exactly.",
            ],
            "last_reply_user_id": [
              "type": "string", "description": "The id in parentheses on that reply's From line.",
            ],
            "last_reply_user_name": [
              "type": "string", "description": "The name on that From line, without the email.",
            ],
          ],
        ],
      ]
    ],
  ]

  public static var selfSystem: String { Prompts.text(.slackSelf) }

  public static let selfSchema: JSON = [
    "type": "object", "required": ["user_id"], "additionalProperties": false,
    "properties": [
      "user_id": [
        "type": "string", "pattern": #"^[UW][A-Z0-9]{2,}$"#,
        "description": "The id on the profile result's User ID line, copied exactly.",
      ]
    ],
  ]

  // MARK: The init check

  public enum InitVerdict: Equatable, Sendable {
    case ok
    /// claude offers these tools beyond the call's own. A retry that denies them can pass.
    case extraTools([String])
    case refuse(String)
  }

  /// Checks claude's init message. It refuses unless the Slack connector is connected on `account` and the tools
  /// hold `StructuredOutput` and `allowed` once each. When every check passes, it returns any tool beyond those as
  /// `extraTools`.
  public static func initCheck(line: String, allowed: String, account: String) -> InitVerdict {
    guard let o = JSON.parse(line)?.object, o["type"]?.string == "system", o["subtype"]?.string == "init" else {
      return .refuse("claude's first message is not its init message")
    }
    guard let slack = o["mcp_servers"]?.array?.first(where: { $0["name"]?.string == server }) else {
      return .refuse("the account at \(account) doesn't load claude.ai connectors")
    }
    let status = slack["status"]?.string ?? "unknown"
    guard status == "connected" else {
      return .refuse("the claude.ai Slack connector is \(oneLine(status, max: 40)) on \(account)")
    }
    guard let names = o["tools"]?.strings else {
      return .refuse("claude's init message lists no tools")
    }
    // Two servers can give one name, and a deny entry can't tell them apart.
    guard Set(names).count == names.count else { return .refuse("claude lists a tool twice") }
    let expected = [structuredTool, allowed]
    let missing = expected.filter { !names.contains($0) }
    guard missing.isEmpty else { return .refuse("claude doesn't offer \(missing.joined(separator: ", "))") }
    let extra = names.filter { !expected.contains($0) }
    return extra.isEmpty ? .ok : .extraTools(extra)
  }

  /// The `onLine` handler of a call whose one tool is `allowed`. It passes system lines until the init message,
  /// checks that message, and refuses any other line before an init that passed. After that init, it passes every
  /// line except a second init. It records the extra tools of a refused init, so the caller can deny them and retry.
  public final class LineHandler {
    let allowed: String
    let account: String
    private var passed = false
    public private(set) var extraTools: [String] = []

    public init(allowed: String, account: String) {
      self.allowed = allowed
      self.account = account
    }

    public func onLine(_ line: String) -> String? {
      // An init holds "init" in its text, or spells a letter of it as a \u escape. A line with neither can't be a
      // second init, so the handler doesn't parse it.
      if passed, !line.contains("init"), !line.contains("\\u") { return nil }
      let o = JSON.parse(line)?.object
      let isInit = o?["type"]?.string == "system" && o?["subtype"]?.string == "init"
      if passed { return isInit ? "claude printed a second init message" : nil }
      guard let type = o?["type"]?.string else {
        return "claude printed a line that is not JSON before its init message"
      }
      guard type == "system" else {
        return "claude printed a \(oneLine(type, max: 40)) message before its init message"
      }
      guard isInit else { return nil }
      switch SlackPoll.initCheck(line: line, allowed: allowed, account: account) {
      case .ok:
        passed = true
        return nil
      case .extraTools(let names):
        extraTools = names
        return "claude offers tools beyond \(allowed): \(oneLine(names.joined(separator: ", "), max: 200))"
      case .refuse(let reason):
        return reason
      }
    }
  }

  /// The `--disallowedTools` entries that remove the tools: a Slack tool by its full name, another server's tool by
  /// its `mcp__<server>` prefix, and any other name by itself. No entry is the Slack server's prefix, which would
  /// remove the call's own tool.
  public static func denyEntries(for tools: [String]) -> [String] {
    var entries: [String] = []
    for name in tools {
      var entry = name
      if !name.hasPrefix(slackPrefix + "__"), name.hasPrefix("mcp__"),
        let end = name.dropFirst("mcp__".count).range(of: "__")
      {
        entry = String(name[..<end.lowerBound])
      }
      guard entry != slackPrefix, entry != slackPrefix + "__", !entries.contains(entry) else { continue }
      entries.append(entry)
    }
    return entries
  }

  // MARK: Parsing the stream

  /// One thread's answer that passed every check.
  public struct ThreadRead: Equatable, Sendable {
    public var count: Int
    public var lastReplyTs: String?
    public var lastReplyUser: String?
    public var lastReplyName: String?
    /// The newest reply in the read whose user is not you, from sbd's own parse of the message headers.
    public var lastOther: Header? = nil
  }

  /// Why sbd didn't accept a thread's answer.
  public struct ReadError: Error, Equatable, CustomStringConvertible {
    public var reason: String

    public init(_ reason: String) { self.reason = reason }

    public var description: String { reason }
  }

  /// The tool calls and tool results in a stream.
  struct Stream {
    struct Call {
      var name: String
      var input: [String: JSON]
      /// The raw text block of its tool result, or nil without a result or with an error result.
      var raw: String?
      /// The text of its tool result.
      var result: String? { raw.map(Stream.text) }
    }

    var calls: [Call] = []
    var envelope: [String: JSON]?

    init(_ output: String) {
      var order: [String] = []
      var uses: [String: (name: String, input: [String: JSON])] = [:]
      var results: [String: String] = [:]
      for line in Headless.lines(output) {
        guard let o = JSON.parse(String(line))?.object else { continue }
        let blocks = o["message"]?["content"]?.array ?? []
        switch o["type"]?.string {
        case "assistant":
          for b in blocks where b["type"]?.string == "tool_use" {
            guard let id = b["id"]?.string, let name = b["name"]?.string, uses[id] == nil else { continue }
            order.append(id)
            uses[id] = (name, b["input"]?.object ?? [:])
          }
        case "user":
          for b in blocks where b["type"]?.string == "tool_result" {
            guard let id = b["tool_use_id"]?.string, b["is_error"]?.bool != true else { continue }
            results[id] = Self.raw(b["content"])
          }
        default:
          break
        }
      }
      calls = order.compactMap { id in
        uses[id].map { Call(name: $0.name, input: $0.input, raw: results[id]) }
      }
      envelope = Headless.envelope(output)
    }

    /// A tool result's content as one text: a plain string, or its text blocks joined.
    static func raw(_ content: JSON?) -> String {
      switch content {
      case .string(let s): s
      case .array(let blocks):
        blocks.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined(separator: "\n")
      default: ""
      }
    }

    /// A tool result's text. The connector answers with one text block that holds a JSON object, such as
    /// `{"messages": "..."}`, so the text is that object's string values.
    static func text(_ raw: String) -> String {
      guard let object = JSON.parse(raw)?.object else { return raw }
      return object.keys.sorted().compactMap { object[$0]?.string }.joined(separator: "\n")
    }

    /// The structured output of a successful call. It throws when the call failed as a whole. Unlike
    /// `Headless.answer`, it reads no JSON from the `result` text, because only `structured_output` passed claude's
    /// check against the schema.
    func answer() throws -> [String: JSON] {
      guard let envelope else { throw ReadError("claude printed no result") }
      if envelope["is_error"]?.bool == true {
        throw ReadError("claude failed: \(oneLine(envelope["result"]?.string ?? "", max: 200))")
      }
      guard let answer = envelope["structured_output"]?.object else { throw ReadError("claude gave no answer") }
      return answer
    }
  }

  /// The result of each asked thread, in the order of `asked`. An answer is accepted only when a `slack_read_thread`
  /// call for exactly the asked channel, ts, and oldest got a result that isn't an error, and the answer says `ok`
  /// with a whole count from 0 to 10000. A count of 0 needs a result that shows no replies. With replies, the last
  /// reply's ts and user id must be well formed, the ts must come after the root and the oldest, and one message
  /// header in that call's result must hold both. An answer for a thread that wasn't asked is dropped. A last reply
  /// more than an hour after `now`, the scan's time, is refused, because a made-up ts would become the oldest of
  /// every later read. It throws when the call failed as a whole.
  ///
  /// An accepted read with replies also gives `lastOther`: among the message headers of the whole-thread results,
  /// the one with the greatest ts whose user is not `you` and whose ts is after the root, after the oldest, and at
  /// most an hour after `now`. sbd takes it from the headers, not from the answer, so the model can't leave a reply
  /// out. A message's text can still hold a made-up header.
  public static func parseThreads(_ output: String, asked: [Ask], you: String, now: Int64) throws
    -> [Result<ThreadRead, ReadError>]
  {
    let stream = Stream(output)
    let answers = try stream.answer()["threads"]?.array ?? []
    return asked.map { ask in
      Result { () throws(ReadError) -> ThreadRead in
        try read(ask, stream: stream, answers: answers, you: you, now: now)
      }
    }
  }

  private static func read(_ ask: Ask, stream: Stream, answers: [JSON], you: String, now: Int64) throws(ReadError)
    -> ThreadRead
  {
    let calls = stream.calls.filter { $0.name == readTool && $0.input == ask.input }
    guard !calls.isEmpty else { throw ReadError("claude didn't read the thread as asked") }
    let answered = calls.filter { $0.raw != nil }
    guard !answered.isEmpty else { throw ReadError("the thread's read got no result") }
    let results = answered.filter { isWholeThread($0.raw ?? "") }.compactMap(\.result)
    guard !results.isEmpty else { throw ReadError("the thread has more messages than one read returns") }
    let mine = answers.filter { $0["channel_id"]?.string == ask.channel && $0["message_ts"]?.string == ask.thread }
    guard mine.count == 1, let answer = mine.first?.object else {
      throw ReadError(mine.isEmpty ? "claude gave no answer for the thread" : "claude answered for the thread twice")
    }
    guard answer["ok"]?.bool == true else {
      throw ReadError("the read failed: \(oneLine(answer["error"]?.string ?? "no reason", max: 200))")
    }
    guard let count = answer["reply_count"]?.int, (0...10000).contains(count) else {
      throw ReadError("claude's reply count is not a whole number from 0 to 10000")
    }
    guard count > 0 else {
      guard results.contains(where: showsNoReplies) else {
        throw ReadError("claude counted no replies, but the thread's read shows replies")
      }
      return ThreadRead(count: 0)
    }
    guard let ts = answer["last_reply_ts"]?.string, let last = tsValue(ts), let root = tsValue(ask.thread),
      last > root
    else { throw ReadError("claude's last reply ts is not a ts after the thread's") }
    let ceiling = (now + 3_600_000) * 1000
    guard last <= ceiling else { throw ReadError("claude's last reply ts is in the future") }
    var floor = root
    if let oldest = ask.oldest {
      guard let value = tsValue(oldest), last > value else {
        throw ReadError("claude's last reply ts is not after the oldest that sbd asked")
      }
      floor = max(root, value)
    }
    guard let user = answer["last_reply_user_id"]?.string, isUserId(user) else {
      throw ReadError("claude's last reply user is not a Slack user id")
    }
    guard results.contains(where: { hasHeader($0, user: user, ts: ts) }) else {
      throw ReadError("no message in the thread's read is from claude's last reply user at its ts")
    }
    let name = answer["last_reply_user_name"]?.string.map { oneLine($0, max: 80) }.flatMap { $0.isEmpty ? nil : $0 }
    let others = results.flatMap(headers(in:)).compactMap { header -> (header: Header, ts: Int64)? in
      guard header.user != you, let value = tsValue(header.ts), value > floor, value <= ceiling else { return nil }
      return (header, value)
    }
    return ThreadRead(
      count: count, lastReplyTs: ts, lastReplyUser: user, lastReplyName: name,
      lastOther: others.max { $0.ts < $1.ts }?.header)
  }

  /// Whether a `slack_read_thread` result holds the whole thread after `oldest`. The connector's result is a JSON
  /// object whose `pagination_info` says "There are no more messages in this thread." when nothing is left to page
  /// through. A count from one page of a longer thread would stay short in every later read.
  static func isWholeThread(_ raw: String) -> Bool {
    JSON.parse(raw)?["pagination_info"]?.string?.contains("no more messages") == true
  }

  /// The user's own Slack id. It is accepted only when a `slack_read_user_profile` call without a `user_id` got a
  /// result that isn't an error, the result holds `User ID: <id>`, and the answer's `user_id` is that id.
  public static func parseSelf(_ output: String) throws -> String {
    let stream = Stream(output)
    let answer = try stream.answer()
    let calls = stream.calls.filter { $0.name == profileTool }
    guard !calls.isEmpty else { throw ReadError("claude didn't read the profile") }
    guard calls.allSatisfy({ $0.input["user_id"] == nil || $0.input["user_id"] == "" }) else {
      throw ReadError("claude read another user's profile")
    }
    let ids = calls.compactMap(\.result).compactMap(profileId)
    guard let id = ids.first else { throw ReadError("the profile read holds no User ID line") }
    guard Set(ids).count == 1, answer["user_id"]?.string == id else {
      throw ReadError("claude's user id is not the one the profile gave")
    }
    return id
  }

  /// The id on the `User ID:` line of a profile, when it is a whole Slack user id.
  static func profileId(_ text: String) -> String? {
    guard let label = text.range(of: "User ID: ") else { return nil }
    let id = String(text[label.upperBound...].prefix { !$0.isWhitespace })
    return isUserId(id) ? id : nil
  }

  static func isUserId(_ text: String) -> Bool { text.wholeMatch(of: #/[UW][A-Z0-9]{2,}/#) != nil }

  /// A Slack ts of the form `1794965246.462679` in microseconds.
  static func tsValue(_ ts: String) -> Int64? {
    guard let m = ts.wholeMatch(of: #/([0-9]{10})\.([0-9]{6})/#), let s = Int64(m.1), let us = Int64(m.2) else {
      return nil
    }
    return s * 1_000_000 + us
  }

  /// Whether a `slack_read_thread` result shows no replies. The connector heads the replies with a line such as
  /// `=== THREAD REPLIES (6 total) ===` and leaves that line out when the read finds none. A message's text can
  /// hold a made-up `(0 total)` line, so any other count on such a line means replies.
  static func showsNoReplies(_ text: String) -> Bool {
    !text.split(separator: "\n").contains {
      $0.hasPrefix("=== THREAD REPLIES") && $0 != "=== THREAD REPLIES (0 total) ==="
    }
  }

  /// One message header of a `slack_read_thread` result.
  public struct Header: Equatable, Sendable {
    public var user: String
    /// The text of the `From:` line before the id, without a trailing `<email>`, or nil when nothing is left.
    public var name: String?
    public var ts: String
  }

  /// The message headers in the text, in its order. The connector writes a header as a `From: Name <email> (U0123)`
  /// line, a `Time:` line, and a `Message TS:` line. So a valid user id must close a `From:` line, and the next
  /// line that isn't a `Time:` line must be a `Message TS:` line with a well formed ts. A mention of a user in a
  /// message's text doesn't count. A message's text can still hold a made-up header.
  static func headers(in text: String) -> [Header] {
    // A Swift string treats CRLF as one character, so this split leaves a CRLF line whole.
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var out: [Header] = []
    for (i, line) in lines.enumerated() where line.hasPrefix("From: ") {
      // A user id holds no parenthesis, so the last one opens the only id that can close the line.
      guard let paren = line.lastIndex(of: "("), line.hasSuffix(")") else { continue }
      let user = String(line[line.index(after: paren)..<line.index(before: line.endIndex)])
      guard isUserId(user), line.hasSuffix(" (\(user))"),
        let next = lines[(i + 1)...].first(where: { !$0.hasPrefix("Time: ") }), next.hasPrefix("Message TS: ")
      else { continue }
      let ts = String(next.dropFirst("Message TS: ".count))
      guard tsValue(ts) != nil else { continue }
      // In `From: (U0123)`, the space after `From:` is also the space before the id.
      let start = line.index(line.startIndex, offsetBy: "From: ".count)
      let space = line.index(before: paren)
      var name = start < space ? String(line[start..<space]) : ""
      name = name.trimmingCharacters(in: .whitespaces)
      if name.hasSuffix(">"), let email = name.lastIndex(of: "<") {
        name = String(name[..<email])
      }
      let clipped = oneLine(name, max: 80)
      out.append(Header(user: user, name: clipped.isEmpty ? nil : clipped, ts: ts))
    }
    return out
  }

  /// Whether one message header in the text holds the user and the ts.
  static func hasHeader(_ text: String, user: String, ts: String) -> Bool {
    headers(in: text).contains { $0.user == user && $0.ts == ts }
  }
}
