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
  /// Another connection, as after a crash, sees none of the writes until
  /// the body ends, and then all of them.
  @Test func transactionKeepsItsWritesFromOtherConnectionsUntilTheEnd() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let other = try Store(path: "\(dir)/sb.db")

    try store.transaction {
      try store.append(Event(session: "s1", t: 1, kind: "sent", data: ["text": "fix it"]))
      #expect(try other.events(session: "s1").isEmpty)
      try store.append(Event(session: "s1", t: 2, kind: "decisions_submitted", data: ["message": "fix it"]))
    }

    #expect(try other.events(session: "s1").map(\.kind) == ["sent", "decisions_submitted"])
  }

  /// A body that throws leaves none of its writes, and the throw reaches the caller.
  @Test func transactionRollsBackABodyThatThrows() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")

    #expect(throws: APIError.self) {
      try store.transaction {
        try store.append(Event(session: "s1", t: 1, kind: "sent", data: ["text": "fix it"]))
        throw APIError("the next write failed")
      }
    }

    #expect(try Store(path: "\(dir)/sb.db").events(session: "s1").isEmpty)
  }

  /// A transaction that can't start runs nothing, so a caller refuses before it acts.
  @Test func transactionRunsNothingWhenItCantStart() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    var ran = false

    _ = try store.transaction {
      #expect(throws: (any Error).self) { try store.transaction { ran = true } }
    }

    #expect(!ran)
  }

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

  @Test func rememberKeepsTheLaterUseOfARepo() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    do {
      let store = try Store(path: "\(dir)/sb.db")
      try store.remember(repo: "/dev/alpha", used: 5)
      try store.remember(repo: "/dev/beta", used: 6)
      try store.remember(repo: "/dev/alpha", used: 9)
      try store.remember(repo: "/dev/alpha", used: 7)
    }

    let rows = try Store(path: "\(dir)/sb.db").knownRepos()

    #expect(Dictionary(uniqueKeysWithValues: rows.map { ($0.path, $0.used) }) == ["/dev/alpha": 9, "/dev/beta": 6])
    #expect(rows.count == 2)
  }

  @Test func knownReposAreEmptyInANewDatabase() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let store = try Store(path: "\(dir)/sb.db")

    #expect(try store.knownRepos().isEmpty)
  }
}

@Suite struct ConfigTests {
  @Test func declinedSuggestionsSurviveReopeningTheStore() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    do {
      let store = try Store(path: "\(dir)/sb.db")
      try store.decline(suggestion: "merge:g1:g2")
      try store.decline(suggestion: "dependency:s1:g1")
      try store.decline(suggestion: "merge:g1:g2")
    }

    let store = try Store(path: "\(dir)/sb.db")

    #expect(try store.declinedSuggestions() == ["merge:g1:g2", "dependency:s1:g1"])
  }

  @Test func aNewStoreHasNoDeclinedSuggestions() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let store = try Store(path: "\(dir)/sb.db")

    #expect(try store.declinedSuggestions().isEmpty)
  }

  @Test func removeDeclinedDeletesOnlyTheNamedRows() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let kept = ["merge:g1:g2", "pab2cd:posthog/posthog#12", "prefix:posthog/posthog#12", "word:eachother", "word"]
    let removed = ["word:each", "dependency:s1:g1", "scope:it's a \"scope\"; --:g1", "prefix:flag-evaluations:g1"]
    for id in kept + removed { try store.decline(suggestion: id) }

    try store.removeDeclined(Set(removed))

    #expect(try Store(path: "\(dir)/sb.db").declinedSuggestions() == Set(kept))
  }

  @Test func removeDeclinedIgnoresAnIdThatIsNotDeclined() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    try store.decline(suggestion: "merge:g1:g2")

    try store.removeDeclined(["merge:g1:g3", "merge:g1", "merge:g1:g2:g3", "%", "merge:g1:g_"])

    #expect(try store.declinedSuggestions() == ["merge:g1:g2"])
  }

  @Test func removeDeclinedWithNoIdsDeletesNothing() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    try store.decline(suggestion: "merge:g1:g2")

    try store.removeDeclined([])

    #expect(try store.declinedSuggestions() == ["merge:g1:g2"])
  }

  @Test func aRemovedDeclineCanBeDeclinedAgain() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    try store.decline(suggestion: "merge:g1:g2")
    try store.removeDeclined(["merge:g1:g2"])

    try store.decline(suggestion: "merge:g1:g2")

    #expect(try store.declinedSuggestions() == ["merge:g1:g2"])
  }

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

/// A resolved to-do's record and the session change that resolves it commit together, or neither does.
@Suite struct ResolvedTodoStoreTests {
  static func todo(_ id: String) -> Note { Note(id: id, text: "tell Alex", by: .claude, t: 10, kind: .todo) }

  static func record(_ session: Session, _ note: Note, how: String) -> ResolvedTodo {
    ResolvedTodo(
      session: session, branch: session.branch, note: note, pr: 12,
      resolution: Note.Resolution(t: 20, by: .you, how: how))
  }

  /// Makes every `when` on `table` abort, as a constraint on the store would.
  static func block(_ when: String, on table: String, in path: String) throws {
    let r = try runCommand(
      "/usr/bin/sqlite3",
      [path, "CREATE TRIGGER block BEFORE \(when) ON \(table) BEGIN SELECT RAISE(ABORT, 'blocked'); END;"])
    try #require(r.status == 0, Comment(rawValue: r.stderr))
  }

  func session() -> Session {
    var s = Session(
      id: "s1", name: "one", cwd: "/tmp/a", repo: "/tmp/repo", branch: "haacked/a", claudeSessionId: "u1", created: 5)
    s.notes = [Self.todo("n1")]
    return s
  }

  @Test func deleteRecordsTheResolvedToDosAndTheyOutliveTheSession() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let s = session()
    try store.save(s)

    try store.delete(
      session: s.id, resolving: [Self.record(s, Self.todo("n1"), how: "resolved and deleted the session")])

    #expect(try store.sessions().isEmpty)
    let rows = try store.resolvedTodos(limit: 50)
    #expect(rows.map(\.note) == ["n1"])
    #expect(rows.first?.repo == "/tmp/repo")
    #expect(rows.first?.branch == "haacked/a")
    #expect(rows.first?.pr == 12)
    #expect(rows.first?.by == .claude)
  }

  @Test func aDeleteThatFailsWritesNoRecord() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let s = session()
    try store.save(s)
    try Self.block("DELETE", on: "sessions", in: "\(dir)/sb.db")

    #expect(throws: APIError.self) {
      try store.delete(
        session: s.id, resolving: [Self.record(s, Self.todo("n1"), how: "resolved and deleted the session")])
    }

    #expect(try store.sessions() == [s])
    #expect(try store.resolvedTodos(limit: 50).isEmpty)
  }

  @Test func aResolveWhoseSessionSaveFailsWritesNoRecord() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let s = session()
    try store.save(s)
    try Self.block("INSERT", on: "sessions", in: "\(dir)/sb.db")
    var resolved = s
    resolved.notes?[0].resolved = Note.Resolution(t: 20, by: .you, how: "resolved")

    #expect(throws: APIError.self) {
      try store.save(resolved, resolving: Self.record(s, Self.todo("n1"), how: "resolved"))
    }

    #expect(try store.sessions() == [s])
    #expect(try store.resolvedTodos(limit: 50).isEmpty)
  }

  @Test func aSessionWithoutARepoBranchOrPRReadsBackAsNil() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let s = Session(id: "s1", name: "one", cwd: "/tmp/a", claudeSessionId: "u1", created: 5)
    try store.save(s)
    var row = Self.record(s, Self.todo("n1"), how: "resolved and deleted the session")
    row.pr = nil

    try store.delete(session: s.id, resolving: [row])

    let read = try #require(try store.resolvedTodos(limit: 50).first)
    #expect(read.repo == nil)
    #expect(read.branch == nil)
    #expect(read.pr == nil)
  }
}
