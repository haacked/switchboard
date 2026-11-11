import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct SidePanelDataTests {
  func decode(_ text: String) throws -> SessionSummary { try JSONCoding.decode(SessionSummary.self, from: text) }

  @Test func getAndLsCarryTheWaitsAndNotesThatTheSidePanelReads() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    try sbd.sb("wait", s.id, "--kind", "date", "--until", "1h", "--note", "check the dashboard", "--then", "notify")
    try sbd.sb(["wait", s.id, "ask", "Alex"], env: ["CLAUDECODE": "1"])
    try sbd.sb("note", s.id, "stacked on #1190")
    try sbd.sb("note", s.id, "--todo", "tell Alex in #flags")

    let got = try decode(sbd.sb("get", "--json", s.id))
    let listed = try JSONCoding.decode([SessionSummary].self, from: try sbd.sb("ls", "--json"))
    let row = try #require(listed.first { $0.id == s.id })

    #expect(got.waits.map(\.kind) == [.date, .manual])
    #expect(got.waits.map(\.by) == [.you, .claude])
    #expect(got.waits.map(\.then) == [.notify, .notify])
    #expect(got.waits.map(\.note) == ["check the dashboard", "ask Alex"])
    #expect(got.waits.map(\.created) == got.waits.map(\.created).sorted())
    #expect(Set(got.waits.map(\.id)).count == 2)
    #expect(got.notes.map(\.text) == ["stacked on #1190", "tell Alex in #flags"])
    #expect(got.notes.map { $0.kind ?? .note } == [.note, .todo])
    #expect(row.waits == got.waits)
    #expect(row.notes == got.notes)

    let first = try #require(got.waits.first)
    try sbd.sb("wait", s.id, "--clear", "--id", first.id)
    let after = try decode(sbd.sb("get", "--json", s.id))

    #expect(after.waits == Array(got.waits.dropFirst()))
    #expect(after.notes == got.notes)
  }
}
