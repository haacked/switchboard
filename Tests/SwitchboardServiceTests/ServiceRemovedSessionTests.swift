import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardService

/// SplitMix64. Two generators with one seed draw one sequence, so they make `newSessionID(using:)` try the same
/// candidate ids in the same order.
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

private let seed: UInt64 = 20_261_113

/// A `Service` in a temporary home. The service never loads, so it starts no tmux server and no claude.
private func withService(_ body: (Service, Home) throws -> Void) throws {
  let home = Home(path: try makeShortTempFolder())
  defer { try? FileManager.default.removeItem(atPath: home.path) }
  let service = try Service(home: home, sbPath: "/usr/bin/true")
  try body(service, home)
}

private func makeSession(_ id: String, name: String) -> Session {
  Session(id: id, name: name, cwd: "/tmp", branch: nil, claudeSessionId: "c-\(id)", model: nil, created: 0)
}

extension Service {
  /// The id that `newSessionID(using:)` returns for a generator with `seed`, given the current live and
  /// removed sessions.
  fileprivate func sessionID(seed: UInt64) -> String {
    var generator = SeededGenerator(state: seed)
    return queue.sync { newSessionID(using: &generator) }
  }

  /// Adds a live session to the service and to the store.
  fileprivate func addLive(_ id: String, name: String) throws {
    let s = makeSession(id, name: name)
    try store.save(s)
    queue.sync { entries[id] = Entry(session: s) }
  }
}

/// sbd keeps each removed session's name in `removedNames`, writes it to the store in the deletion, and never
/// issues a removed session's id again.
@Suite struct ServiceRemovedSessionTests {
  // MARK: newSessionID

  /// The tests below rely on this: the same seed and the same taken ids give the same id.
  @Test func oneSeedGivesOneId() throws {
    try withService { service, _ in
      let first = service.sessionID(seed: seed)

      #expect(service.sessionID(seed: seed) == first)
      #expect(first.count == 6 && first.hasPrefix("s"), "\(first)")
    }
  }

  @Test func newSessionIDSkipsALiveId() throws {
    try withService { service, _ in
      let first = service.sessionID(seed: seed)
      try service.addLive(first, name: "live")

      #expect(service.sessionID(seed: seed) != first)
    }
  }

  @Test func newSessionIDSkipsARemovedId() throws {
    try withService { service, _ in
      let first = service.sessionID(seed: seed)
      service.queue.sync { service.removedNames[first] = "zsh-startup-for-switchboard" }

      let next = service.sessionID(seed: seed)

      #expect(next != first)
      #expect(next.count == 6 && next.hasPrefix("s"), "\(next)")
    }
  }

  /// The generator's first candidate is removed and its second is live, in either order, so the id is its third.
  @Test(arguments: [true, false])
  func newSessionIDSkipsLiveAndRemovedIdsTogether(removedFirst: Bool) throws {
    try withService { service, _ in
      let first = service.sessionID(seed: seed)
      try service.addLive(first, name: "probe")
      let second = service.sessionID(seed: seed)
      service.queue.sync { service.entries[first] = nil }
      let (removed, live) = removedFirst ? (first, second) : (second, first)
      service.queue.sync { service.removedNames[removed] = "gone" }
      try service.addLive(live, name: "live")

      let next = service.sessionID(seed: seed)

      #expect(first != second)
      #expect(![first, second].contains(next), "\(next) is \(removedFirst ? "first" : "second")'s candidate")
    }
  }

  // MARK: forgetSession

  @Test func forgetSessionRecordsTheNameInRemovedNames() throws {
    try withService { service, _ in
      try service.addLive("sgcctv", name: "zsh-startup-for-switchboard")

      try service.queue.sync { try service.forgetSession("sgcctv", resolving: []) }

      #expect(service.queue.sync { service.removedNames["sgcctv"] } == "zsh-startup-for-switchboard")
      #expect(service.queue.sync { service.entries["sgcctv"] } == nil)
    }
  }

  @Test func forgetSessionWritesTheRemovalToTheStore() throws {
    try withService { service, home in
      try service.addLive("sgcctv", name: "zsh-startup-for-switchboard")

      try service.queue.sync { try service.forgetSession("sgcctv", resolving: []) }

      let rows = try Store(path: home.database).removedSessions()
      #expect(rows.map(\.id) == ["sgcctv"])
      #expect(rows.map(\.name) == ["zsh-startup-for-switchboard"])
    }
  }

  /// The removal in `forgetSession` and the creation in `newSessionID` together keep an old mention of the id
  /// from resolving to a new, unrelated session.
  @Test func theIdOfAForgottenSessionIsNotIssuedAgain() throws {
    try withService { service, _ in
      let first = service.sessionID(seed: seed)
      try service.addLive(first, name: "zsh-startup-for-switchboard")
      try service.queue.sync { try service.forgetSession(first, resolving: []) }

      #expect(service.sessionID(seed: seed) != first)
    }
  }

  @Test func aForgetRefusedForAnOpenToDoRecordsNoName() throws {
    try withService { service, home in
      var s = makeSession("sgcctv", name: "zsh-startup-for-switchboard")
      s.notes = [Note(id: "n1", text: "tell Alex", by: .claude, t: 10, kind: .todo)]
      try service.store.save(s)
      service.queue.sync { service.entries[s.id] = Service.Entry(session: s) }

      #expect(throws: OpenTodoError.self) { try service.queue.sync { try service.forgetSession(s.id, resolving: []) } }

      #expect(service.queue.sync { service.removedNames[s.id] } == nil)
      #expect(service.queue.sync { service.entries[s.id] } != nil)
      #expect(try Store(path: home.database).removedSessions().isEmpty)
    }
  }

  /// `forgetSession` updates `removedNames` only after the store call succeeds.
  @Test func aForgetThatTheStoreRefusesRecordsNoName() throws {
    try withService { service, home in
      try service.addLive("sgcctv", name: "zsh-startup-for-switchboard")
      let r = try runCommand(
        "/usr/bin/sqlite3",
        [home.database, "CREATE TRIGGER block BEFORE DELETE ON sessions BEGIN SELECT RAISE(ABORT, 'blocked'); END;"])
      try #require(r.status == 0, Comment(rawValue: r.stderr))

      #expect(throws: (any Error).self) {
        try service.queue.sync { try service.forgetSession("sgcctv", resolving: []) }
      }

      #expect(service.queue.sync { service.removedNames["sgcctv"] } == nil)
      #expect(service.queue.sync { service.entries["sgcctv"] } != nil)
      #expect(try Store(path: home.database).removedSessions().isEmpty)
    }
  }

  // MARK: cleanupBlocker

  static let pr = PullRequest(id: "PR_1", number: 7, url: "u", repo: "mac/repo", state: .merged)

  @Test func theCleanupBlockerOfARemovedSessionNamesItFirst() throws {
    try withService { service, _ in
      service.queue.sync { service.removedNames["sgcctv"] = "zsh-startup-for-switchboard" }

      #expect(service.cleanupBlocker("sgcctv", pr: Self.pr) == "zsh-startup-for-switchboard (sgcctv) is gone")
    }
  }

  /// No name exists for an id that sbd never recorded as removed, so the id stays bare.
  @Test func theCleanupBlockerOfAnUnknownIdKeepsTheBareId() throws {
    try withService { service, _ in
      #expect(service.cleanupBlocker("sgcctv", pr: Self.pr) == "sgcctv is gone")
    }
  }

  // MARK: Source audit

  /// Each `shortId("s"` in `Sources`, with the name of the nearest `func` above it.
  static func sessionIdDraws() throws -> [(file: String, function: String?)] {
    let pattern = try Regex(#"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)|shortId\(\s*"s""#)
    return try SourceAudit.sourceFiles().flatMap { source -> [(file: String, function: String?)] in
      let (file, text) = source
      var function: String?
      var draws: [(file: String, function: String?)] = []
      for match in text.matches(of: pattern) {
        if let name = match.output[1].substring {
          function = String(name)
        } else {
          draws.append((file: file, function: function))
        }
      }
      return draws
    }
  }

  /// All five creation paths (`new`, follow-up add, follow-up import, `import`, docket review) get their id from
  /// `newSessionID`, so each one avoids removed ids.
  @Test func onlyNewSessionIDDrawsASessionId() throws {
    let draws = try Self.sessionIdDraws()

    #expect(!draws.isEmpty)
    let elsewhere = draws.filter { $0.function != "newSessionID" }
    #expect(elsewhere.isEmpty, "shortId(\"s\" is called outside newSessionID at \(elsewhere)")
  }
}
