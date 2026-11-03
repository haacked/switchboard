import Testing

@testable import SwitchboardCore

@Suite struct BoardRowsTests {
  func summary(_ id: String, group: String? = nil) -> SessionSummary {
    var s = SessionSummary(
      id: id, name: id, cwd: "/tmp", repo: nil, branch: nil, claudeSessionId: id, state: .working, reason: "",
      since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
    s.group = group
    return s
  }

  func group(_ id: String, _ name: String, _ sessions: [String]) -> GroupSummary {
    GroupSummary(SessionGroup(id: id, name: name, created: 0), sessions: sessions)
  }

  func layout(_ sessions: [SessionSummary], _ groups: [GroupSummary]) -> [String] {
    BoardRows.make(sessions: sessions, groups: groups).map {
      "\($0.group ?? "-") \($0.title): \($0.sessions.map(\.id).joined(separator: ","))"
    }
  }

  @Test func givesARowPerGroupInTheOrderOfTheList() {
    let sessions = [summary("a", group: "gz"), summary("b", group: "ga"), summary("c", group: "gz")]

    let rows = layout(sessions, [group("gz", "Zeta", ["a", "c"]), group("ga", "Alpha", ["b"])])

    #expect(rows == ["gz Zeta: a,c", "ga Alpha: b"])
  }

  @Test func putsUngroupedSessionsInALastRowWithNoGroup() {
    let sessions = [summary("u1"), summary("a", group: "g1"), summary("u2")]

    let rows = BoardRows.make(sessions: sessions, groups: [group("g1", "Flags", ["a"])])

    #expect(rows.map(\.group) == ["g1", nil])
    #expect(rows.last?.title == "Ungrouped")
    #expect(rows.last?.sessions.map(\.id) == ["u1", "u2"])
  }

  @Test func leavesOutTheUngroupedRowWhenEverySessionHasAGroup() {
    let rows = layout([summary("a", group: "g1")], [group("g1", "Flags", ["a"])])

    #expect(rows == ["g1 Flags: a"])
  }

  @Test func keepsTheRowOfAGroupWithNoSessionsOnTheBoard() {
    let rows = layout([summary("u")], [group("g1", "Flags", [])])

    #expect(rows == ["g1 Flags: ", "- Ungrouped: u"])
  }

  @Test func givesNoRowsForAnEmptyBoard() {
    #expect(BoardRows.make(sessions: [], groups: []).isEmpty)
  }

  @Test func keepsTheOrderOfTheSessionsInsideARow() {
    let sessions = [summary("c", group: "g1"), summary("a", group: "g1"), summary("b", group: "g1")]

    let rows = layout(sessions, [group("g1", "Flags", ["a", "b", "c"])])

    #expect(rows == ["g1 Flags: c,a,b"])
  }

  @Test func aSessionWhoseGroupIsNotListedStaysOnTheBoardAsUngrouped() {
    let rows = layout([summary("a", group: "gone")], [group("g1", "Flags", [])])

    #expect(rows == ["g1 Flags: ", "- Ungrouped: a"])
  }
}
