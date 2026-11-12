import Foundation
import SwitchboardCore
import Testing

extension Instance {
  @discardableResult
  func recordActivity(_ events: [ActivityEvent]) throws -> JSON {
    try client.call("activity-record", ["events": try JSON(encoding: events)])
  }

  /// The rows of the activity log, oldest first, read straight from the database.
  func activityRows() throws -> [ActivityEvent] {
    try Store(path: home.database).activity()
  }
}

@Suite(.blocking(timeLimit: .seconds(120))) struct ActivityRecordTests {
  static let nav = ActivityEvent(t: 1000, kind: "nav", data: ["to": "board", "via": "list"])

  @Test func storesNothingWhileTheLogIsOff() throws {
    let sbd = try Instance()

    let result = try sbd.recordActivity([Self.nav])

    #expect(result["stored"]?.int == 0)
    #expect(try sbd.activityRows().isEmpty)
  }

  @Test func storesOnlyTheEventsThatPassEveryRule() throws {
    let sbd = try Instance()
    try sbd.sb("activity", "on")
    let extraField = ActivityEvent(t: 2, kind: "nav", data: ["to": "board", "query": "secret"])
    let unknownKind = ActivityEvent(t: 3, kind: "search", data: ["query": "secret"])
    let messageAsCode = ActivityEvent(t: 4, kind: "error", data: ["where": "send", "code": "can't reach /tmp/x"])
    let wordAsPlace = ActivityEvent(t: 5, kind: "error", data: ["where": "rebase-onto-main-please"])
    let unknownSession = ActivityEvent(t: 6, kind: "nav", session: "sabcde", data: ["to": "session"])

    let result = try sbd.recordActivity([Self.nav, extraField, unknownKind, messageAsCode, wordAsPlace, unknownSession])

    #expect(result["stored"]?.int == 1)
    #expect(result["refused"]?.int == 5)
    #expect(try sbd.activityRows() == [ActivityEvent(id: 1, t: 1000, kind: "nav", data: Self.nav.data)])
  }

  @Test func storesAnEventForASessionThatSbdKnows() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: "t")
    try sbd.sb("activity", "on")

    try sbd.recordActivity([ActivityEvent(t: 1, kind: "nav", session: s.id, data: ["to": "session"])])

    #expect(try sbd.activityRows().map(\.session) == [s.id])
  }

  @Test func aSendThatNamesASenderIsNotTheUsers() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.sb("activity", "on")

    _ = try sbd.client.call("send", ["session": .string(s.id), "text": "note to self", "from": .string(s.id)])
    _ = try sbd.client.call("send", ["session": .string(s.id), "text": "from a gone session", "from": "sgone2"])

    #expect(try sbd.activityRows().filter { $0.kind == "send" }.isEmpty)
  }

  @Test func aSendKeepsAHashOfTheTextAndNotTheText() throws {
    let sbd = try Instance()
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    try sbd.sb("activity", "on")

    try sbd.sb("send", s.id, "Fix the failing  CI")
    _ = try sbd.client.call("send", ["session": .string(s.id), "text": "fix the failing ci", "via": "field"])
    try sbd.sb("send", s.id, "something else")

    let sends = try sbd.waitFor("three send rows", fetch: { try sbd.activityRows().filter { $0.kind == "send" } }) {
      $0.count == 3
    }
    let hashes = sends.map { $0.data["textHash"]?.string }
    #expect(hashes[0] != nil && hashes[0] == hashes[1] && hashes[1] != hashes[2])
    #expect(sends.map { $0.data["via"]?.string } == ["cli", "field", "cli"])
    #expect(sends.allSatisfy { $0.session == s.id && $0.data["delivery"]?.string != nil })
    #expect(!(try sbd.activityRows().contains { $0.data.text.lowercased().contains("failing") }))
    let mode = try FileManager.default.attributesOfItem(atPath: sbd.home.activityKey)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    #expect(try sbd.sb("activity", "report").contains("texts sent more than once"))
  }

  @Test func aGroupMessageIsOneSendWithItsTargetCount() throws {
    let sbd = try Instance()
    try sbd.sb("activity", "on")
    let group = try JSONCoding.decode(GroupSummary.self, from: try sbd.sb("group", "add", "--json", "Flags")).id
    for name in ["a", "b"] {
      let s = try sbd.client.call(
        "new", ["path": .string(sbd.work), "prompt": "hello", "group": .string(group), "name": .string(name)],
        as: SessionSummary.self)
      try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    }
    let targets =
      try sbd.client.call("send-group", ["group": .string(group), "text": "rebase please"])["targets"]?
      .array?.compactMap { $0["id"]?.string } ?? []

    _ = try sbd.client.call(
      "send-group",
      [
        "group": .string(group), "text": "rebase please", "confirmed": true,
        "targets": .array(targets.map(JSON.string)),
      ])

    let sends = try sbd.activityRows().filter { $0.kind == "send" }
    #expect(sends.count == 1)
    #expect(sends.first?.data["via"]?.string == "group")
    #expect(sends.first?.data["targets"]?.int == 2)
    #expect(sends.first?.session == nil)
  }
}
