import Foundation
import Testing

@testable import SwitchboardCore

/// A new folder in the temporary folder. A database needs a folder of its
/// own, because WAL mode adds files next to it.
func tempFolder() throws -> String {
  let dir = NSTemporaryDirectory() + "sb-test-\(UUID().uuidString)"
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  return dir
}

@Suite struct StoreTests {
  @Test func sessionsAndEventsRoundTrip() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var s = Session(id: "s1", name: "one", cwd: "/tmp/a", branch: "main", claudeSessionId: "u1", created: 5)
    s.waitNote = "CI"
    s.waits = [
      Wait(
        id: "w1", kind: .botReview, pr: Wait.PullRequest(repository: "PostHog/posthog", number: 1204), who: "ReviewHog",
        by: .claude, created: 6),
      Wait(
        id: "w2", kind: .deploy, pr: Wait.PullRequest(number: 1204), environment: "prod-us", service: "feature-flags",
        note: "merge when green", created: 7, then: .notify),
      Wait(
        id: "w3", kind: .session, session: Wait.SessionTarget(id: "s2", name: "flag-cache"), state: .needsYou,
        created: 8),
      Wait(id: "w4", kind: .date, until: 90_000, created: 9),
    ]
    s.notes = [Note(id: "n1", text: "ask Alex about the cache", by: .claude, t: 10)]
    s.claudeConfigDir = "/Users/me/.claude-personal"
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

  @Test func v01SessionRowDecodesWithNoWaitsOrNotes() throws {
    let row = """
      {"claudeSessionId": "u1", "created": 5, "cwd": "/tmp/a", "done": false, "id": "s1", "name": "one",
       "started": true, "waitNote": "CI on #12"}
      """
    let s = try JSONCoding.decode(Session.self, from: row)
    #expect(s.waitNote == "CI on #12")
    #expect(s.waits == nil)
    #expect(s.notes == nil)
  }

  @Test func aSessionThatAnOlderSbdStoredHasNoAccount() throws {
    let json = #"{"id":"s1","name":"one","cwd":"/a","claudeSessionId":"u1","created":5,"started":true,"done":false}"#

    #expect(try JSONCoding.decode(Session.self, from: json).claudeConfigDir == nil)
  }

  @Test func claudeSessionsRoundTripInIdOrder() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let two = ClaudeSession(
      id: "u2", name: "fix-ci", cwd: "/w/two", account: "/Users/me/.claude-personal", status: "busy", job: "701cd24a",
      pid: 57910, seen: 10, repo: "docket", branch: "haacked/two", worktree: true)
    var one = ClaudeSession(id: "u1", cwd: "/w/one", account: "/Users/me/.claude", seen: 5)
    do {
      let store = try Store(path: "\(dir)/sb.db")
      try store.save(claudeSessions: [two, one])
      one.seen = 20
      try store.save(claudeSessions: [two, one])
    }

    let store = try Store(path: "\(dir)/sb.db")

    #expect(try store.claudeSessions() == [one, two])
    try store.delete(claudeSession: "u2")
    #expect(try store.claudeSessions() == [one])
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

  /// An empty list names no accounts. Only a missing one means discover them.
  @Test(
    arguments: [
      (#"{"claudeConfigDirs": ["~/.claude", "~/.claude-personal"]}"#, ["~/.claude", "~/.claude-personal"]),
      (#"{"claudeConfigDirs": []}"#, []),
      ("{}", nil),
    ] as [(String, [String]?)])
  func claudeConfigDirsIsNilOnlyWhenMissing(_ text: String, _ dirs: [String]?) throws {
    #expect(try JSONCoding.decode(Config.self, from: text).claudeConfigDirs == dirs)
  }
}
