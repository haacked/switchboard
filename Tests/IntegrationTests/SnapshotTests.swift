import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// How the last start built each session: the loaded state, by session.
  func loaded() throws -> [String: JSON] {
    let rows = try client.call("snapshots", [:]).array ?? []
    return Dictionary(uniqueKeysWithValues: rows.map { ($0["session"]!.string!, $0) })
  }

  /// What a user sees of the sessions, without the processes' details.
  func shown() throws -> [JSON] {
    try client.call("ls", ["all": .bool(true)]).array?.map { row in
      var row = row.object ?? [:]
      for key in ["claudePid", "attached", "live", "openPrompt"] { row[key] = nil }
      return .object(row)
    } ?? []
  }

  /// How many events the session's log has past its saved snapshot, or Int64.max without one.
  func snapshotLag(_ id: String) -> Int64 {
    guard let store = try? Store(path: home.database), let text = try? store.snapshot(session: id),
      let snapshot = try? JSONCoding.decode(SessionSnapshot.self, from: text),
      let last = try? store.events(session: id, limit: 1, newest: true).last
    else { return .max }
    return last.id - snapshot.replay.lastEvent
  }

  func restart(snapshotEvery: Int) throws { try restart(setting: "snapshotEvery", to: .number(Double(snapshotEvery))) }
}

@Suite(.blocking(timeLimit: .seconds(180))) struct SnapshotTests {
  /// Sessions with a PR and a wait, a queued message, a card, and notes, and
  /// then more events after a snapshot.
  func busyInstance() throws -> (Instance, [String]) {
    let github = try FakeGitHub()
    let sbd = try Instance.withGitHub(github)
    let reviewed = try sbd.session(in: "PostHog/charts", branch: "haacked/cdp-dlq-runbook-lookup-step")
    try sbd.poll()
    try sbd.sb("wait", reviewed.id, "CI", "on", "#18303")
    try sbd.sb("note", reviewed.id, "ask", "about", "the", "cache")
    let queued = try sbd.new(prompt: "slow 120", name: "queued")
    try sbd.waitFor(queued.id, "the turn") { $0.state == .working }
    #expect(try sbd.sb("send", queued.id, "first") == "queued\n")
    let asking = try sbd.new(prompt: "perm touch x", name: "asking")
    try sbd.waitFor(asking.id, "the card") { !$0.cards.isEmpty }
    try sbd.sb("note", asking.id, "later")
    try sbd.sb("snapshots", "--write")

    #expect(try sbd.sb("send", queued.id, "second") == "queued\n")
    github.change(18303) { $0["mergeable"] = "CONFLICTING" }
    try sbd.poll(all: true)
    return (sbd, [reviewed.id, queued.id, asking.id])
  }

  @Test func aRestartFromSnapshotsBuildsWhatAFullReplayBuilds() throws {
    let (sbd, ids) = try busyInstance()
    try sbd.restart(snapshotEvery: 500)
    let loaded = try sbd.loaded()
    for id in ids { #expect(loaded[id]?["loaded"]?.string?.hasPrefix("snapshot + ") == true, "\(id)") }
    #expect(loaded[ids[1]]?["replay"]?["pending"] == ["first", "second"])
    let withSnapshots = try sbd.shown()
    let cards = try sbd.cards()

    try sbd.restart(snapshotEvery: 0)
    let replayed = try sbd.loaded()
    for id in ids { #expect(replayed[id]?["loaded"]?.string?.hasPrefix("replay of ") == true, "\(id)") }
    for id in ids { #expect(loaded[id]?["replay"] == replayed[id]?["replay"], "\(id)") }
    #expect(try sbd.shown() == withSnapshots)
    #expect(try sbd.cards() == cards)
  }

  @Test func aStartAfterASnapshotAppliesOnlyTheEventsAfterIt() throws {
    let (sbd, ids) = try busyInstance()
    try sbd.restart(snapshotEvery: 500)
    #expect(try sbd.loaded()[ids[0]]?["loaded"]?.string?.hasPrefix("snapshot + ") == true)
    // That start saved the events it applied, so the next one applies none.
    try sbd.restart(snapshotEvery: 500)
    for id in ids { #expect(try sbd.loaded()[id]?["loaded"] == "snapshot + 0 events", "\(id)") }
  }

  @Test func sbdSavesASnapshotWhileItRuns() throws {
    let sbd = try Instance(config: ["snapshotEvery": 3])
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: hello" }
    try sbd.waitFor("a snapshot near the log's end", timeout: 10) {
      try sbd.events(s.id).count >= 3 && sbd.snapshotLag(s.id) < 3
    }
    try sbd.restart(snapshotEvery: 3)
    let note = try #require(try sbd.loaded()[s.id]?["loaded"]?.string)
    #expect(note.hasPrefix("snapshot + "))
    #expect(try sbd.get(s.id).lastReply == "Done: hello")
  }

  @Test func aSessionWithAChangedRowIsReplayedInFull() throws {
    let (sbd, ids) = try busyInstance()
    sbd.stopSbd()
    // Changing the row while sbd is down leaves no time for the saver to catch up.
    let store = try Store(path: sbd.home.database)
    var changed = try #require(try store.sessions().first { $0.id == ids[2] })
    changed.done = true
    try store.save(changed)
    try sbd.startSbd()
    let loaded = try sbd.loaded()
    #expect(loaded[ids[2]]?["loaded"]?.string?.contains("session changed") == true)
    #expect(loaded[ids[0]]?["loaded"]?.string?.hasPrefix("snapshot + ") == true)
  }

  @Test func removingASessionLeavesNoSnapshot() throws {
    let sbd = try Instance(config: ["snapshotEvery": 3])
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the reply") { $0.lastReply == "Done: hello" }
    try sbd.sb("snapshots", "--write")
    try sbd.sb("rm", s.id)
    sbd.stopSbd()
    let store = try Store(path: sbd.home.database)
    #expect(try store.snapshot(session: s.id) == nil)
  }
}
