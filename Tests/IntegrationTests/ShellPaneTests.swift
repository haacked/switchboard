import Foundation
import SwitchboardCore
import Testing

@Suite(.blocking(timeLimit: .seconds(120))) struct ShellPaneTests {
  enum Kind: String, CaseIterable, Sendable {
    case work, manager, chat

    /// How `create` makes a conversation of this kind, or nil for a work session.
    var conversation: Conversation? {
      switch self {
      case .work: nil
      case .manager: .manager
      case .chat: .chat
      }
    }
  }

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// A live session of the kind, with both panes running. A conversation starts with its shell closed, so this
  /// opens it.
  func session(_ sbd: Instance, _ kind: Kind) throws -> SessionSummary {
    let s = try kind.conversation.map { try create(sbd, $0) } ?? sbd.new(prompt: "hello")
    #expect(s.kind.rawValue == kind.rawValue)
    let live = try sbd.waitFor(s.id, "claude") { $0.live && $0.claudePid != nil }
    guard kind != .work else { return live }
    _ = try sbd.sb("shell", s.id, "--open")
    try waitForShell(sbd, try sbd.client.terminals(s.id))
    return try sbd.get(s.id)
  }

  func waitForShell(_ sbd: Instance, _ t: Terminals) throws {
    try sbd.waitFor("the shell to run") {
      try sbd.tmux("display-message", "-p", "-t", "=\(t.shell):", "#{pane_dead}").stdout.hasPrefix("0")
    }
  }

  /// Checks that the shell is gone and stays gone, and that claude keeps running in the same process.
  func expectClosed(_ sbd: Instance, _ s: SessionSummary, _ t: Terminals) throws {
    let closed = try sbd.waitFor(s.id, "the shell to close") { $0.shellClosed == true }
    try sbd.waitFor("the shell's tmux session to end") { try !sbd.hasTmuxSession(t.shell) }
    #expect(closed.live)
    #expect(closed.claudePid == s.claudePid)
    try sbd.expectShellAbsent(s.id)
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
    #expect(try sbd.hasTmuxSession(t.shell))
    try waitForShell(sbd, t)
    #expect(try sbd.get(s.id).claudePid == s.claudePid)
  }

  // MARK: A new conversation starts with its shell closed

  /// Each way sbd creates a Manager conversation, a group chat, or the operator. A first prompt launches claude
  /// inside `create`.
  enum Conversation: String, CaseIterable, Sendable {
    case manager, managerNewWithPrompt, chat, chatWithPrompt, theOperator

    var kind: SessionKind {
      switch self {
      case .manager, .managerNewWithPrompt: .manager
      case .chat, .chatWithPrompt: .chat
      case .theOperator: .operator
      }
    }
  }

  /// Creates the conversation and returns sbd's answer to the request that created it.
  func create(_ sbd: Instance, _ shape: Conversation) throws -> SessionSummary {
    let s: SessionSummary
    switch shape {
    case .manager:
      s = try decode(SessionSummary.self, sbd.sb("manager", "--json"))
    case .managerNewWithPrompt:
      s = try decode(SessionSummary.self, sbd.sb("manager", "new", "--json", "hello"))
    case .chat, .chatWithPrompt:
      let member = try sbd.new(name: "member")
      let group = try decode(GroupSummary.self, sbd.sb("group", "add", "--json", "g1", member.id))
      let prompt = shape == .chatWithPrompt ? ["--send", "hello"] : []
      s = try decode(SessionSummary.self, sbd.sb(["chat", group.id, "--json"] + prompt))
    case .theOperator:
      s = try decode(SessionSummary.self, sbd.sb("operator", "--json"))
    }
    #expect(s.kind == shape.kind)
    return s
  }

  @Test(arguments: Conversation.allCases) func aNewConversationStartsWithTheShellClosed(_ shape: Conversation) throws {
    let sbd = try Instance()

    let s = try create(sbd, shape)

    #expect(s.shellClosed == true)
    #expect(try !sbd.hasTmuxSession("\(s.id)-shell"))
    try sbd.expectShellAbsent(s.id)
  }

  @Test func aNewConversationsShellStaysClosedAfterSbdRestarts() throws {
    let sbd = try Instance()
    let s = try create(sbd, .manager)
    try sbd.waitFor(s.id, "claude") { $0.live && $0.claudePid != nil }

    sbd.stopSbd()
    try sbd.startSbd()

    try sbd.expectShellAbsent(s.id)
  }

  /// The exit and close tests open the shell of a new Manager conversation and a new chat through `session`, so
  /// this test covers the operator alone.
  @Test func openingTheShellOfTheNewOperatorStartsIt() throws {
    let sbd = try Instance()
    let s = try sbd.waitFor(try create(sbd, .theOperator).id, "claude") { $0.live && $0.claudePid != nil }
    let t = try sbd.client.terminals(s.id)

    let opened = try decode(SessionSummary.self, sbd.sb("shell", s.id, "--open", "--json"))

    #expect(opened.shellClosed != true)
    #expect(try sbd.hasTmuxSession(t.shell))
    try waitForShell(sbd, t)
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
    #expect(try !sbd.hasTmuxSession(t.shell))
  }

  @Test(arguments: [true, false]) func shellRefusesAFollowupThatHasNotStarted(open: Bool) throws {
    let sbd = try Instance()
    let f = try add(sbd, ["prompt": "Fix the cache. It reads twice.", "repository": "acme/widgets"])
    let error = failure(sbd, "shell", ["session": .string(f.id), "open": .bool(open)])
    #expect(error.contains("hasn't started"))
    let listed = try JSONCoding.decode([SessionSummary].self, from: try sbd.sb("followup", "ls", "--json"))
    #expect(listed.first { $0.id == f.id }?.shellClosed == nil)
  }

  @Test func shellNeedsOpenOrClose() throws {
    let sbd = try Instance()
    let s = try sbd.new()
    let r = try sbd.run("shell", s.id)
    #expect(r.status != 0)
    #expect(r.stderr.contains("--open or --close"))
  }
}

extension Instance {
  func hasTmuxSession(_ target: String) throws -> Bool {
    try tmux("has-session", "-t", "=\(target)").status == 0
  }

  /// Requires that claude runs and the shell does not, after the app and `sb open` ask for the terminals.
  func expectShellAbsent(_ id: String) throws {
    try waitFor(id, "claude") { $0.live && $0.claudePid != nil }
    let t = try client.terminals(id)
    _ = try sb("open", id)
    #expect(try hasTmuxSession(t.claude))
    #expect(try !hasTmuxSession(t.shell))
    #expect(try get(id).shellClosed == true)
  }
}
