import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// Sends a hook of the session's claude, as `sb hook` does for a local claude. `fields` go into the payload
  /// next to `hook_event_name` and `session_id`.
  func postHook(_ id: String, _ kind: String, _ fields: [String: JSON] = [:]) throws {
    var payload = fields
    payload["hook_event_name"] = .string(kind)
    payload["session_id"] = .string(try get(id).claudeSessionId)
    _ = try client.call("hook", ["session": .string(id), "payload": .object(payload)])
  }

  /// A Notification hook that changes no turn.
  func postProbe(_ id: String) throws {
    try postHook(id, "Notification", ["notification_type": "sb_test", "message": "probe"])
  }

  /// An idle session whose events after `mark` are a PostToolUse, a Notification, three notes, and two
  /// Notifications. The newest events and the oldest events after `mark` are then not notes, so a limit that sbd
  /// applied before the kind filter would drop notes.
  func interleavedSession() throws -> (id: String, mark: Int64) {
    let s = try idleSession()
    let mark = try lastEventId(s.id)
    try postHook(s.id, "PostToolUse", ["tool_name": "Bash", "tool_use_id": "toolu_other"])
    try postProbe(s.id)
    for i in 1...3 { try addPlainNote(s.id, "note \(i)") }
    try postProbe(s.id)
    try postProbe(s.id)
    return (s.id, mark)
  }

  /// The events that `sb events --json` prints, one per line.
  func sbEvents(_ args: String...) throws -> [Event] {
    try sb(["events", "--json"] + args).split(separator: "\n").map {
      try JSONCoding.decode(Event.self, from: String($0))
    }
  }

  /// The `data` of each of the session's events as sbd's database holds it, by event id. It stops sbd first.
  func storedEventData(_ id: String) throws -> [Int64: JSON] {
    stopSbd()
    let r = try sqlite("SELECT id, data FROM events WHERE session = '\(id)'", "-json")
    try #require(r.status == 0, Comment(rawValue: r.stderr))
    let rows = try #require(JSON.parse(r.stdout)?.array)
    return try Dictionary(
      uniqueKeysWithValues: rows.map { row in
        let id = try #require(row["id"]?.int)
        let data = try #require(row["data"]?.string.flatMap(JSON.parse))
        return (Int64(id), data)
      })
  }
}

/// Text and payloads whose strings store differently: ASCII, a letter that takes two bytes in UTF-8, and
/// characters that JSON escapes.
enum SlimFixtures {
  static let alphabets: [[Character]] = [["a"], ["é"], ["\"", "\\", "\n", "\t"]]

  static func text(_ alphabet: [Character], _ count: Int) -> String {
    String((0..<count).map { alphabet[$0 % alphabet.count] })
  }

  /// 1000 characters of the alphabet, then 500 tildes that the cut must drop.
  static func long(_ alphabet: [Character]) -> String { text(alphabet, 1000) + String(repeating: "~", count: 500) }

  /// A PostToolUse hook's fields, with long strings at the top, in a nested object, in an array, and in an object
  /// inside an array. `tool_input` also holds a `tool_response` key that is not at the top.
  static func toolFields(_ alphabet: [Character], response: JSON, toolUseId: String) -> [String: JSON] {
    let cut = JSON.string(long(alphabet))
    return [
      "tool_name": "Bash", "tool_use_id": .string(toolUseId), "duration_ms": 812, "cwd": "/tmp",
      "permission_mode": "default", "message": cut,
      "tool_input": [
        "command": cut, "description": "ls", "exact": .string(text(alphabet, 1000)),
        "over": .string(text(alphabet, 1000) + "~"), "tool_response": ["kept": true],
        "list": [cut, ["deep": cut], 7],
      ],
      "tool_response": response,
    ]
  }

  static let smallResponse: JSON = ["stdout": "hello", "stderr": "", "interrupted": false]
  static let largeResponse = JSON.string(String(repeating: "x", count: 5000))

  /// A `tool_response` to slim, and the least length that its note can name.
  enum Response: CaseIterable, Sendable, CustomTestStringConvertible {
    case smallObject, largeString

    var json: JSON { self == .smallObject ? smallResponse : largeResponse }
    var length: Int { self == .smallObject ? 1 : 5000 }
    var testDescription: String { "\(self)" }
  }

  /// Every number in the text, with thousands separators dropped.
  static func numbers(_ text: String) -> [Int] {
    text.replacingOccurrences(of: ",", with: "").split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
  }
}

/// The `events` request's `kinds` and `full`, sent straight to sbd.
@Suite(.blocking(timeLimit: .seconds(120))) struct EventsRequestTests {
  // MARK: kinds

  @Test(arguments: [false, true])
  func kindsFilterBeforeTheLimit(withSince: Bool) throws {
    let sbd = try Instance()
    let (id, mark) = try sbd.interleavedSession()
    let notes = try sbd.events(id, after: mark).filter { $0.kind == "note" }.map(\.id)
    try #require(notes.count == 3)
    var args: [String: JSON] = ["session": .string(id), "limit": 2, "kinds": ["note"]]
    if withSince { args["since"] = .number(Double(mark)) }

    let listed = try sbd.client.call("events", args, as: [Event].self)

    #expect(listed.map(\.id) == Array(withSince ? notes.prefix(2) : notes.suffix(2)))
  }

  @Test(arguments: [false, true])
  func kindsListsEveryEventOfEachKindAndNoOther(withSince: Bool) throws {
    let sbd = try Instance()
    let (id, mark) = try sbd.interleavedSession()
    let all = try sbd.events(id, after: withSince ? mark : 0)
    let expected = all.filter { ["note", "Notification"].contains($0.kind) }.map(\.id)
    try #require(all.count > expected.count, "the session has no event of another kind")
    var args: [String: JSON] = ["session": .string(id), "limit": 10_000, "kinds": ["note", "Notification"]]
    if withSince { args["since"] = .number(Double(mark)) }

    let listed = try sbd.client.call("events", args, as: [Event].self)

    #expect(listed.map(\.id) == expected)
  }

  @Test(arguments: [false, true])
  func anEmptyKindsListsNoEvents(withSince: Bool) throws {
    let sbd = try Instance()
    let (id, _) = try sbd.interleavedSession()
    var args: [String: JSON] = ["session": .string(id), "kinds": []]
    if withSince { args["since"] = 0 }

    let listed = try sbd.client.call("events", args, as: [Event].self)

    #expect(listed.isEmpty, "\(listed.map(\.kind))")
  }

  @Test(arguments: [.string("Stop"), .array([.string("Stop"), .number(1)])] as [JSON])
  func kindsThatIsNotAListOfStringsFails(kinds: JSON) throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()

    let message = failure(sbd, "events", ["session": .string(s.id), "kinds": kinds])

    #expect(message.contains("kinds needs a list of event kinds"), "\(message)")
  }

  // MARK: Slim data

  /// The tool event of a PostToolUse hook with the fields, read without `full`.
  func slimToolEvent(_ alphabet: [Character], response: JSON) throws -> (posted: [String: JSON], read: JSON) {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let toolUseId = "toolu_\(UUID().uuidString)"
    let fields = SlimFixtures.toolFields(alphabet, response: response, toolUseId: toolUseId)
    try sbd.postHook(s.id, "PostToolUse", fields)

    let listed = try sbd.client.call(
      "events", ["session": .string(s.id), "since": 0, "limit": 10_000], as: [Event].self)

    let event = try #require(listed.last { $0.data["tool_use_id"]?.string == toolUseId })
    return (fields, event.data)
  }

  @Test(arguments: SlimFixtures.Response.allCases)
  func withoutFullTheToolResponseIsAShortNoteThatNamesItsLengthAndFull(response: SlimFixtures.Response) throws {
    let (_, read) = try slimToolEvent(["a"], response: response.json)

    let note = try #require(read["tool_response"]?.string, "tool_response is \(read["tool_response"]?.text ?? "nil")")
    #expect(note.contains("full"), "\(note)")
    #expect(note.count < 200, "\(note)")
    #expect(SlimFixtures.numbers(note).contains { $0 >= response.length }, "\(note)")
  }

  @Test(arguments: SlimFixtures.alphabets)
  func withoutFullAStringLongerThan1000CharactersIsCutAndNamesTheCut(alphabet: [Character]) throws {
    let (_, read) = try slimToolEvent(alphabet, response: SlimFixtures.smallResponse)
    let kept = SlimFixtures.text(alphabet, 1000)
    let input = read["tool_input"]
    let list = input?["list"]?.array
    let longOnes: [(String, JSON?)] = [
      ("message", read["message"]), ("tool_input.command", input?["command"]),
      ("tool_input.list[0]", list?[0]), ("tool_input.list[1].deep", list?[1]["deep"]),
    ]

    for (path, value) in longOnes {
      let text = try #require(value?.string, "\(path) is \(value?.text ?? "nil")")
      let rest = String(text.dropFirst(1000))
      #expect(text.hasPrefix(kept), "\(path) lost its first 1000 characters")
      #expect(!rest.contains("~~~~"), "\(path) kept the cut part: \(rest)")
      #expect(SlimFixtures.numbers(rest).contains(500), "\(path) does not name the 500 cut characters: \(rest)")
    }
    let over = try #require(input?["over"]?.string)
    #expect(over.hasPrefix(kept) && !over.contains("~"), "a 1001-character string was not cut: \(over.suffix(40))")
  }

  @Test(arguments: SlimFixtures.alphabets)
  func withoutFullShortValuesAndOtherKeysAreUnchanged(alphabet: [Character]) throws {
    let (posted, read) = try slimToolEvent(alphabet, response: SlimFixtures.smallResponse)
    let input = read["tool_input"]

    for key in ["tool_name", "tool_use_id", "duration_ms", "cwd", "permission_mode"] {
      #expect(read[key] == posted[key], "\(key)")
    }
    #expect(input?["description"] == "ls")
    #expect(input?["exact"] == .string(SlimFixtures.text(alphabet, 1000)))
    #expect(input?["tool_response"] == ["kept": true])
    #expect(input?["list"]?.array?[2] == 7)
  }

  @Test(arguments: [false, true])
  func withFullTheDataIsWhatSbdStored(withSince: Bool) throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let toolUseId = "toolu_\(UUID().uuidString)"
    for alphabet in SlimFixtures.alphabets {
      try sbd.postHook(
        s.id, "PostToolUse",
        SlimFixtures.toolFields(alphabet, response: SlimFixtures.largeResponse, toolUseId: toolUseId))
    }
    var args: [String: JSON] = ["session": .string(s.id), "limit": 10_000, "full": true]
    if withSince { args["since"] = 0 }

    let listed = try sbd.client.call("events", args, as: [Event].self)

    let stored = try sbd.storedEventData(s.id)
    try #require(listed.filter { $0.data["tool_use_id"]?.string == toolUseId }.count == SlimFixtures.alphabets.count)
    for event in listed {
      #expect(event.data == stored[event.id], "event \(event.id) \(event.kind)")
    }
  }
}

/// `sb events --kind`, `--limit`, and `--full`.
@Suite(.blocking(timeLimit: .seconds(120))) struct EventsCommandTests {
  @Test func eachKindFlagAddsAKind() throws {
    let sbd = try Instance()
    let (id, _) = try sbd.interleavedSession()
    let all = try sbd.events(id)
    let expected = all.filter { ["note", "Notification"].contains($0.kind) }.map(\.id)
    try #require(all.count > expected.count, "the session has no event of another kind")

    let listed = try sbd.sbEvents("--session", id, "--kind", "note", "--kind", "Notification")

    #expect(listed.map(\.id) == expected)
  }

  @Test func limitListsTheNewestEventsOfTheKind() throws {
    let sbd = try Instance()
    let (id, _) = try sbd.interleavedSession()
    let notes = try sbd.events(id).filter { $0.kind == "note" }.map(\.id)

    let listed = try sbd.sbEvents("--session", id, "--kind", "note", "--limit", "2")

    #expect(listed.map(\.id) == Array(notes.suffix(2)))
  }

  @Test func withoutALimitItListsTheNewest200() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    for i in 0...200 { try sbd.addPlainNote(s.id, "note \(i)") }
    let newest = try sbd.events(s.id).suffix(200).map(\.id)

    let listed = try sbd.sbEvents("--session", s.id)

    #expect(listed.count == 200)
    #expect(listed.map(\.id) == Array(newest))
  }

  @Test func fullPrintsTheToolResponseThatTheDefaultLeavesOut() throws {
    let sbd = try Instance()
    let s = try sbd.idleSession()
    let toolUseId = "toolu_\(UUID().uuidString)"
    try sbd.postHook(
      s.id, "PostToolUse",
      ["tool_name": "Bash", "tool_use_id": .string(toolUseId), "tool_response": SlimFixtures.smallResponse])

    let full = try sbd.sbEvents("--session", s.id, "--full").last { $0.data["tool_use_id"]?.string == toolUseId }
    let slim = try sbd.sbEvents("--session", s.id).last { $0.data["tool_use_id"]?.string == toolUseId }

    #expect(full?.data["tool_response"] == SlimFixtures.smallResponse)
    #expect(slim?.data["tool_response"]?.string != nil, "\(slim?.data["tool_response"]?.text ?? "nil")")
  }
}
