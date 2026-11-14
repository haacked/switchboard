import Foundation
import Testing

@testable import SwitchboardCore

@Suite struct SnapshotTests {
  let session = Session(id: "s1", name: "one", cwd: "/tmp/a", branch: "main", claudeSessionId: "u1", created: 5)

  func store() throws -> (Store, String) {
    let dir = try tempFolder()
    return (try Store(path: "\(dir)/sb.db"), dir)
  }

  func tool(_ name: String, _ command: String) -> JSON {
    ["tool_name": .string(name), "tool_use_id": .string("t-\(command)"), "tool_input": ["command": .string(command)]]
  }

  /// Events that leave an open card, a deferred card, queued messages, a
  /// message whose paste may not have arrived, a PR with comments, an sbd
  /// message, and a running turn.
  func history(_ t: inout Int64) -> [Event] {
    func e(_ kind: String, _ data: JSON = [:]) -> Event {
      t += 1000
      return Event(session: "s1", t: t, kind: kind, data: data)
    }
    let pr = PullRequest(id: "PR_1", number: 7, url: "https://github.com/a/b/pull/7", repo: "a/b", title: "A change")
    let comments = [
      PRComment(id: "IC_1", author: "greptile-apps[bot]", createdAt: "2026-10-01T10:00:00Z", body: "Race.")
    ]
    return [
      e("started"), e("SessionStart", ["transcript_path": "/tmp/t.jsonl"]),
      e("UserPromptSubmit", ["prompt": "hello"]),
      e("sent", ["text": "one", "delivery": "queued"]), e("sent", ["text": "two", "delivery": "queued"]),
      e("requeued", ["text": "three"]), e("delivered", ["text": "one"]),
      e("sent", ["text": "wake up", "delivery": "pasted", "by": "sbd"]),
      e("sent", ["text": "four", "delivery": "pasted", "awaits_delivered": true]), e("pasting", ["text": "four"]),
      e("sent", ["text": "five", "delivery": "pasted", "awaits_delivered": true]), e("pasting", ["text": "five"]),
      e("delivered", ["text": "five"]),
      e("sent", ["text": "six", "delivery": "queued"]), e("pasting", ["text": "six"]),
      e("delivery_unknown", ["text": "six"]),
      e("PermissionRequest", tool("Bash", "touch x")),
      e("pr", ["pr": try! JSON(encoding: pr), "comments": try! JSON(encoding: comments)]),
      e("PostToolUse", tool("Bash", "touch x")), e("Stop", ["last_assistant_message": "Done. Want me to push?"]),
      e("UserPromptSubmit", ["prompt": "again"]), e("PreToolUse", tool("Bash", "sleep 9")),
      e("PermissionRequest", tool("Bash", "rm -rf build")),
      e("worktree", ["dirty": 3]),
    ]
  }

  func append(_ events: [Event], to store: Store) throws {
    for event in events { try store.append(event) }
  }

  func fullReplay(_ store: Store, _ session: Session) throws -> SessionReplay {
    .replaying(try store.events(session: session.id), session: session)
  }

  @Test func theSnapshotAndTheTailBuildWhatAFullReplayBuilds() throws {
    let (store, dir) = try store()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try store.save(session)
    var t: Int64 = 0
    let events = history(&t)
    for cut in 1..<events.count {
      try store.delete(session: session.id, name: session.name)
      try store.save(session)
      try append(Array(events[..<cut]), to: store)
      let first = try Snapshots.refresh(store, session, build: "b1")
      #expect(first.outcome == .replay("no snapshot", events: cut))
      try append(Array(events[cut...]), to: store)
      let second = try Snapshots.refresh(store, session, build: "b1")
      #expect(second.outcome == .snapshot(tail: events.count - cut))
      #expect(second.snapshot.replay == (try fullReplay(store, session)))
    }
    let again = try Snapshots.refresh(store, session, build: "b1")
    #expect(again.outcome == .snapshot(tail: 0))
  }

  @Test func aTriageSummaryComesBackFromTheSnapshotAndFromTheTail() throws {
    let (store, dir) = try store()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try store.save(session)
    try store.append(Event(session: "s1", t: 1000, kind: "UserPromptSubmit", data: ["prompt": "go"]))
    let stop = try store.append(
      Event(session: "s1", t: 2000, kind: "Stop", data: ["last_assistant_message": "Which database should I use?"]))
    // The snapshot holds the Stop, and the summary arrives in the tail.
    try Snapshots.refresh(store, session, build: "b1")
    let summary = Event(
      session: "s1", t: 3000, kind: "triage",
      data: [
        "stop": .number(Double(stop.id)), "title": "Pick a database", "kind": "decision", "summary": "Which one.",
        "options": [],
      ])
    try store.append(summary)
    let fromTail = try Snapshots.refresh(store, session, build: "b1")
    #expect(fromTail.outcome == .snapshot(tail: 1))
    #expect(fromTail.snapshot.replay.facts.triage?.title == "Pick a database")
    #expect(fromTail.snapshot.replay == (try fullReplay(store, session)))
    // The snapshot now holds the summary, and a later prompt drops it.
    try store.append(Event(session: "s1", t: 4000, kind: "UserPromptSubmit", data: ["prompt": "Use Postgres."]))
    let after = try Snapshots.refresh(store, session, build: "b1")
    #expect(after.snapshot.replay.facts.triage == nil)
    #expect(after.snapshot.replay == (try fullReplay(store, session)))
  }

  @Test func theReplayKeepsQueuedMessagesAndCards() throws {
    let (store, dir) = try store()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try store.save(session)
    var t: Int64 = 0
    try append(history(&t), to: store)
    let replay = try Snapshots.refresh(store, session, build: "b1").snapshot.replay
    // "wake up" is a direct paste from an sbd that recorded no `delivered` for it.
    // "four" started its paste with no `delivered`.
    #expect(replay.pending == ["two", "three"])
    #expect(replay.uncertain == ["four"])
    #expect(replay.facts.cards.map(\.input) == [["command": "rm -rf build"]])
    #expect(replay.facts.pr?.number == 7)
    #expect(replay.facts.prComments.map(\.id) == ["IC_1"])
    #expect(replay.facts.dirty == 3)
    #expect(replay.lastEvent == (try store.events(session: "s1").last?.id))
  }

  @Test(arguments: ["a new build", "a changed session", "a snapshot that does not decode", "a missing event"])
  func aSnapshotThatMayBeStaleFallsBackToAFullReplay(problem: String) throws {
    let (store, dir) = try store()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try store.save(session)
    var t: Int64 = 0
    let events = history(&t)
    try append(Array(events[..<8]), to: store)
    try Snapshots.refresh(store, session, build: "b1")
    try append(Array(events[8...]), to: store)
    var build = "b1"
    var current = session
    switch problem {
    case "a new build": build = "b2"
    case "a changed session": current.done = true
    case "a snapshot that does not decode": try store.save(snapshot: #"{"build":"b1"}"#, session: "s1")
    default:
      // A snapshot that names an event this session's log doesn't have.
      var snapshot = try #require(try Snapshots.refresh(store, session, build: "b1").snapshot as SessionSnapshot?)
      snapshot.replay.lastEvent = 999_999
      try store.save(snapshot: JSONCoding.encode(snapshot), session: "s1")
    }
    let result = try Snapshots.refresh(store, current, build: build)
    guard case .replay(_, let count) = result.outcome else {
      Issue.record("expected a full replay, got \(result.outcome)")
      return
    }
    #expect(count == events.count)
    #expect(result.snapshot.replay == (try fullReplay(store, current)))
    #expect(try Snapshots.refresh(store, current, build: build).outcome == .snapshot(tail: 0))
  }

  @Test func removingASessionRemovesItsSnapshot() throws {
    let (store, dir) = try store()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try store.save(session)
    var t: Int64 = 0
    try append(history(&t), to: store)
    try Snapshots.refresh(store, session, build: "b1")
    #expect(try store.snapshot(session: "s1") != nil)
    try store.delete(session: "s1", name: "one")
    #expect(try store.snapshot(session: "s1") == nil)
  }

  @Test func theStateSinceFollowsTheSessionAtReplay() throws {
    // A full replay tracks every event under the session it is given, so a
    // snapshot made under another session must not be reused.
    let (store, dir) = try store()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try store.save(session)
    var t: Int64 = 0
    try append(history(&t), to: store)
    var done = session
    done.done = true
    let before = try Snapshots.refresh(store, session, build: "b1").snapshot
    let after = try Snapshots.refresh(store, done, build: "b1").snapshot
    #expect(before.replay.facts.stateSince != after.replay.facts.stateSince)
    #expect(after.replay.facts.lastState == .done)
  }
}
