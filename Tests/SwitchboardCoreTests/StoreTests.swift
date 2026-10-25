import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct StoreTests {
  /// A folder for the database, because WAL mode adds files next to it.
  func tempFolder() throws -> String {
    let dir = NSTemporaryDirectory() + "sb-store-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test func sessionsAndEventsRoundTrip() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var s = Session(id: "s1", name: "one", cwd: "/tmp/a", branch: "main", claudeSessionId: "u1", created: 5)
    s.waitNote = "CI"
    do {
      let store = try Store(path: "\(dir)/sb.db")
      try store.save(s)
      try store.append(Event(session: "s1", t: 10, kind: "Stop", data: ["last_assistant_message": "it's done"]))
      try store.append(Event(session: "s2", t: 11, kind: "SessionStart"))
      try store.append(Event(session: "s1", t: 12, kind: "SessionEnd"))
    }
    let store = try Store(path: "\(dir)/sb.db")
    #expect(try store.sessions() == [s])
    let events = try store.events()
    #expect(events.map(\.kind) == ["Stop", "SessionStart", "SessionEnd"])
    #expect(events[0].data["last_assistant_message"]?.string == "it's done")
    #expect(try store.events(since: events[0].id).map(\.session) == ["s2", "s1"])
    #expect(try store.events(session: "s1").count == 2)
    #expect(try store.events(limit: 2, newest: true).map(\.kind) == ["SessionStart", "SessionEnd"])
    try store.delete(session: "s1")
    #expect(try store.sessions().isEmpty)
    #expect(try store.events(session: "s1").isEmpty)
  }
}

@Suite struct ConfigTests {
  @Test func missingFieldsKeepTheirDefaults() throws {
    let c = try JSONCoding.decode(
      Config.self, from: #"{"idleStopSeconds": 30, "env": {"CLAUDE_CONFIG_DIR": "~/.claude-personal"}}"#)
    #expect(c.idleStopSeconds == 30)
    #expect(c.claude == "claude")
    #expect(c.tickSeconds == 1)
    #expect(c.env["CLAUDE_CONFIG_DIR"] == "~/.claude-personal")
  }
}
