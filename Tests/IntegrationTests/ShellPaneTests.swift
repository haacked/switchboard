import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct ShellPaneTests {
  enum Kind: String, CaseIterable, Sendable { case work, manager, chat }

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// A live session of the kind, with both panes running.
  func session(_ sbd: Instance, _ kind: Kind) throws -> SessionSummary {
    let s: SessionSummary
    switch kind {
    case .work:
      s = try sbd.new(prompt: "hello")
    case .manager:
      s = try decode(SessionSummary.self, sbd.sb("manager", "--json"))
    case .chat:
      let member = try sbd.new(name: "member")
      let group = try decode(GroupSummary.self, sbd.sb("group", "add", "--json", "g1", member.id))
      s = try decode(SessionSummary.self, sbd.sb("chat", group.id, "--json"))
    }
    #expect(s.kind.rawValue == kind.rawValue)
    return try sbd.waitFor(s.id, "claude") { $0.live && $0.claudePid != nil }
  }

  func has(_ sbd: Instance, _ target: String) throws -> Bool {
    try sbd.tmux("has-session", "-t", "=\(target)").status == 0
  }

  /// Checks that the shell is gone and stays gone, and that claude keeps running in the same process.
  func expectClosed(_ sbd: Instance, _ s: SessionSummary, _ t: Terminals) throws {
    let closed = try sbd.waitFor(s.id, "the shell to close") { $0.shellClosed == true }
    try sbd.waitFor("the shell's tmux session to end") { try !has(sbd, t.shell) }
    #expect(closed.live)
    #expect(closed.claudePid == s.claudePid)
    #expect(try has(sbd, t.claude))
    // The app asks for the terminals each time it shows the session.
    _ = try sbd.client.terminals(s.id)
    _ = try sbd.sb("open", s.id)
    #expect(try !has(sbd, t.shell))
    #expect(try sbd.get(s.id).shellClosed == true)
  }

  @Test(arguments: Kind.allCases) func exitInTheShellClosesItAndClaudeRunsOn(kind: Kind) throws {
    let sbd = try Instance()
    let s = try session(sbd, kind)
    let t = try sbd.client.terminals(s.id)
    #expect(try sbd.get(s.id).shellClosed != true)
    #expect(try sbd.tmux("send-keys", "-t", "=\(t.shell):", "exit", "Enter").status == 0)
    try expectClosed(sbd, s, t)
  }

  @Test func ctrlDInTheShellClosesIt() throws {
    let sbd = try Instance()
    let s = try session(sbd, .work)
    let t = try sbd.client.terminals(s.id)
    #expect(try sbd.tmux("send-keys", "-t", "=\(t.shell):", "C-d").status == 0)
    try expectClosed(sbd, s, t)
  }

  @Test func closeEndsOnlyTheShellAndOpenStartsANewOne() throws {
    let sbd = try Instance()
    let s = try session(sbd, .manager)
    let t = try sbd.client.terminals(s.id)
    let closed = try decode(SessionSummary.self, sbd.sb("shell", s.id, "--close", "--json"))
    #expect(closed.shellClosed == true)
    try expectClosed(sbd, s, t)

    let opened = try decode(SessionSummary.self, sbd.sb("shell", s.id, "--open", "--json"))
    #expect(opened.shellClosed != true)
    #expect(try has(sbd, t.shell))
    try sbd.waitFor("the new shell to run") {
      try sbd.tmux("display-message", "-p", "-t", "=\(t.shell):", "#{pane_dead}").stdout.hasPrefix("0")
    }
    #expect(try sbd.get(s.id).claudePid == s.claudePid)
  }

  @Test func aClosedShellStaysClosedAfterSbdRestarts() throws {
    let sbd = try Instance()
    let s = try session(sbd, .work)
    let t = try sbd.client.terminals(s.id)
    _ = try sbd.sb("shell", s.id, "--close")
    sbd.stopSbd()
    try sbd.startSbd()
    #expect(try sbd.get(s.id).shellClosed == true)
    _ = try sbd.client.terminals(s.id)
    #expect(try !has(sbd, t.shell))
  }

  @Test func shellNeedsOpenOrClose() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try sbd.run("shell", s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("--open or --close"))
  }
}
