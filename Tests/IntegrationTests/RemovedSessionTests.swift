import Foundation
import SwitchboardCore
import Testing

extension Instance {
  /// The rows of the `removed-ls` request, which the app reads.
  func removedSessions() throws -> [RemovedSession] {
    try client.call("removed-ls", as: [RemovedSession].self)
  }

  /// The rows that `sb ls --removed --json` prints, with `extra` arguments after it.
  func listRemoved(_ extra: String...) throws -> [RemovedSession] {
    try JSONCoding.decode([RemovedSession].self, from: try sb(["ls", "--removed", "--json"] + extra))
  }
}

/// sbd records each removed session's name and time, serves them through `removed-ls` and `sb ls --removed`, and
/// keeps them across a restart.
@Suite(.blocking(timeLimit: .seconds(120))) struct RemovedSessionTests {
  static let name = "zsh-startup-for-switchboard"

  @Test func lsRemovedJsonListsTheIdNameAndTimeOfARemovedSession() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: Self.name)
    let before = try sbd.now()

    try sbd.sb("rm", s.id)

    let after = try sbd.now()
    let rows = try sbd.listRemoved()
    #expect(rows.map(\.id) == [s.id])
    #expect(rows.map(\.name) == [Self.name])
    let removed = try #require(rows.first?.removed)
    #expect(before <= removed && removed <= after, "\(removed) is outside \(before)...\(after)")
  }

  @Test func theListSurvivesARestartOfSbd() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: Self.name)
    try sbd.sb("rm", s.id)
    let listed = try sbd.listRemoved()

    sbd.stopSbd()
    try sbd.startSbd()

    #expect(listed.map(\.id) == [s.id])
    #expect(try sbd.listRemoved() == listed)
    #expect(try sbd.removedSessions() == listed)
  }

  @Test func theRequestAnswersLikeTheCommand() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: Self.name)
    try sbd.sb("rm", s.id)

    let rows = try sbd.removedSessions()

    #expect(rows.map(\.id) == [s.id])
    #expect(rows == (try sbd.listRemoved()))
  }

  @Test func aNewSbdListsNoRemovedSessions() throws {
    let sbd = try Instance()

    #expect(try sbd.listRemoved().isEmpty)
    #expect(try sbd.removedSessions().isEmpty)
  }

  @Test func aLiveSessionIsNotListed() throws {
    let sbd = try Instance()
    let gone = try sbd.new(name: Self.name)
    let live = try sbd.new(name: "flag-cache")

    try sbd.sb("rm", gone.id)

    #expect(try sbd.listRemoved().map(\.id) == [gone.id])
    #expect(try sbd.client.sessions().map(\.id) == [live.id])
  }

  @Test func theNewestRemovalComesFirst() throws {
    let sbd = try Instance()
    let older = try sbd.new(name: "flag-cache")
    let newer = try sbd.new(name: Self.name)
    try sbd.sb("rm", older.id)
    try sbd.advanceClock(1_000)

    try sbd.sb("rm", newer.id)

    #expect(try sbd.removedSessions().map(\.id) == [newer.id, older.id])
    #expect(try sbd.listRemoved().map(\.id) == [newer.id, older.id])
  }

  /// `followup-rm` deletes through `forgetSession` too.
  @Test func followupRmRecordsTheFollowupsName() throws {
    let sbd = try Instance()
    let f = try add(sbd, ["prompt": "Fix the cache.", "repository": "acme/widgets"])

    try sbd.sb("followup", "rm", f.id)

    #expect(try sbd.listRemoved().map(\.id) == [f.id])
    #expect(try sbd.listRemoved().map(\.name) == [f.name])
  }

  /// A removed session has no org, so `--org` changes nothing.
  @Test func lsRemovedIgnoresTheOrgFilter() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: Self.name)
    try sbd.sb("rm", s.id)

    #expect(try sbd.listRemoved("--org", "posthog").map(\.id) == [s.id])
    #expect(try sbd.listRemoved("--local").map(\.id) == [s.id])
  }

  @Test func lsRemovedPrintsTheIdTheNameAndWhenItWasRemoved() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: Self.name)
    try sbd.sb("rm", s.id)

    let text = try sbd.sb("ls", "--removed")

    let lines = text.split(separator: "\n").map(String.init)
    #expect(lines.contains { $0.hasPrefix("\(s.id)  \(Self.name)  removed ") }, Comment(rawValue: text))
  }

  @Test func theUsageTextDocumentsRemoved() throws {
    let sbd = try Instance()

    #expect(try sbd.sb("help").contains("--removed"))
  }

  // MARK: A refused removal records nothing

  @Test func anRmRefusedForAnOpenToDoRecordsNoRemoval() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: Self.name)
    try sbd.addTodo(s.id, "tell Alex in #flags that the fix shipped")

    let r = try sbd.run("rm", s.id)

    #expect(r.status != 0)
    #expect(r.stderr.contains("\(Self.name) (\(s.id)) has an open to-do"), Comment(rawValue: r.stderr))
    #expect(try sbd.client.sessions().map(\.id) == [s.id])
    #expect(try sbd.listRemoved().isEmpty)
  }

  @Test func anRmThatTheStoreRefusesRecordsNoRemoval() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: Self.name)
    try sbd.block("DELETE", on: "sessions")

    let r = try sbd.run("rm", s.id)

    #expect(r.status != 0)
    #expect(r.stderr.contains("store is read-only"), Comment(rawValue: r.stderr))
    #expect(try sbd.client.sessions().map(\.id) == [s.id])
    #expect(try sbd.listRemoved().isEmpty)
  }

  /// A store that can't record the removal refuses the whole deletion, so no session is deleted without its name.
  @Test func anRmWhoseRemovalTheStoreCannotRecordKeepsTheSession() throws {
    let sbd = try Instance()
    let s = try sbd.new(name: Self.name)
    try sbd.block("INSERT", on: "removed_sessions")

    let r = try sbd.run("rm", s.id)

    #expect(r.status != 0)
    #expect(r.stderr.contains("store is read-only"), Comment(rawValue: r.stderr))
    #expect(try sbd.client.sessions().map(\.id) == [s.id])
    #expect(try sbd.listRemoved().isEmpty)
  }
}
