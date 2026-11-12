import Foundation
import SwitchboardCore
import Testing

/// `sb open --terminals` opens the session and returns its tmux targets in the same request, so the app
/// makes one request for a stopped session.
@Suite(.blocking(timeLimit: .seconds(120))) struct OpenTerminalsTests {
  func live(_ sbd: Instance) throws -> SessionSummary {
    let s = try sbd.new(prompt: "hello")
    return try sbd.waitFor(s.id, "the first reply") { $0.live && $0.claudePid != nil && $0.lastReply == "Done: hello" }
  }

  func stopped(_ sbd: Instance) throws -> SessionSummary {
    let s = try live(sbd)
    try sbd.sb("stop", s.id)
    return try sbd.waitFor(s.id, "claude to exit") { !$0.live }
  }

  func launches(_ sbd: Instance, _ id: String, after mark: Int64) throws -> Int {
    try sbd.events(id, after: mark).filter { ["started", "resumed"].contains($0.kind) }.count
  }

  @Test(arguments: [true, false]) func returnsTheSummaryAndTheTerminalsOfTheTerminalsRequest(live: Bool) throws {
    let sbd = try Instance()
    let s = try live ? self.live(sbd) : stopped(sbd)

    let text = try sbd.sb("open", s.id, "--terminals", "--json")

    #expect(try JSONCoding.decode(SessionSummary.self, from: text).id == s.id)
    let terminals = try Terminals(opened: JSONCoding.decode(JSON.self, from: text))
    #expect(try sbd.client.terminals(s.id) == terminals)
  }

  /// A dead Claude pane stays in tmux, and a missing one makes `terminals` start claude too.
  @Test(arguments: [false, true]) func resumesAStoppedClaudeOnce(paneMissing: Bool) throws {
    let sbd = try Instance()
    let s = try stopped(sbd)
    let claude = try sbd.client.terminals(s.id).claude
    if paneMissing {
      #expect(try sbd.tmux("kill-session", "-t", "=\(claude)").status == 0)
    }
    let mark = try #require(try sbd.events(s.id).last?.id)
    let runs = sbd.stubArgs().count

    _ = try sbd.client.open(s.id)

    try sbd.waitFor(s.id, "claude to resume") { $0.live }
    // Two ticks give a second launch time to show.
    sleep(2)
    #expect(try launches(sbd, s.id, after: mark) == 1)
    #expect(sbd.stubArgs().count == runs + 1)
  }

  @Test func leavesALiveClaudeRunning() throws {
    let sbd = try Instance()
    let s = try live(sbd)
    let mark = try #require(try sbd.events(s.id).last?.id)

    _ = try sbd.client.open(s.id)

    sleep(1)
    #expect(try sbd.get(s.id).claudePid == s.claudePid)
    #expect(try launches(sbd, s.id, after: mark) == 0)
  }

  @Test func leavesAClosedShellClosed() throws {
    let sbd = try Instance()
    let s = try live(sbd)
    let shell = try sbd.client.terminals(s.id).shell
    _ = try sbd.sb("shell", s.id, "--close")
    try sbd.waitFor("the shell's tmux session to end") { try sbd.tmux("has-session", "-t", "=\(shell)").status != 0 }

    #expect(try sbd.client.open(s.id).shell == shell)
    #expect(try sbd.tmux("has-session", "-t", "=\(shell)").status != 0)
    #expect(try sbd.get(s.id).shellClosed == true)
  }

  @Test func plainOpenReturnsTheSummaryAlone() throws {
    let sbd = try Instance()
    let s = try live(sbd)

    let text = try sbd.sb("open", s.id, "--json")

    #expect(try JSONCoding.decode(SessionSummary.self, from: text).id == s.id)
    #expect(try JSONCoding.decode(JSON.self, from: text)["terminals"] == nil)
  }
}
