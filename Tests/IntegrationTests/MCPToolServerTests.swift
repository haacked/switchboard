import Foundation
import SwitchboardCore
import Testing

/// The values and types that the `sb mcp-server` suites share.
enum MCPToolServerTests {
  static let allTools: Set<String> = [
    "list_sessions", "get_session", "read_reply", "triage", "events", "send", "send_group", "spawn", "set_wait",
    "clear_wait", "add_note", "list_groups", "add_group", "remove_group", "move_to_group", "add_group_note",
    "suggest_groups", "plan_artifact",
  ]
  /// The tools that a scoped server leaves out.
  static let unscopedOnly: Set<String> = ["add_group", "remove_group", "suggest_groups"]
  static let hourMs: Int64 = 3600 * 1000

  /// Flags holds `member`. Billing holds `outside`. `loose` is in no group.
  struct Scope {
    let group: GroupSummary
    let other: GroupSummary
    let member: SessionSummary
    let outside: SessionSummary
    let loose: SessionSummary
  }

  /// How a command can name a session or a group: its id, a prefix of its id, or its name.
  enum Naming: CaseIterable { case id, idPrefix, name }

  /// The JSON object after `--mcp-config ` that names the switchboard server.
  /// The stub joins its arguments with spaces. The config is compact JSON
  /// with no braces in its strings.
  static func switchboardConfig(in launch: String) -> JSON? {
    guard let start = launch.range(of: #"--mcp-config {"mcpServers":{"switchboard""#) else { return nil }
    let text = launch[launch.index(start.lowerBound, offsetBy: "--mcp-config ".count)...]
    var depth = 0
    for i in text.indices {
      if text[i] == "{" { depth += 1 }
      if text[i] == "}" { depth -= 1 }
      if depth == 0 { return JSON.parse(String(text[...i])) }
    }
    return nil
  }
}

/// The helpers of the suites that drive `sb mcp-server`.
protocol MCPToolServerSuite {}

extension MCPToolServerSuite {
  typealias Scope = MCPToolServerTests.Scope
  typealias Naming = MCPToolServerTests.Naming

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// The environment of a command that Claude runs inside the session.
  func inside(_ id: String) -> [String: String] { ["SB_SESSION_ID": id, "CLAUDECODE": "1"] }

  func addGroup(_ sbd: Instance, _ name: String, _ sessions: String...) throws -> GroupSummary {
    try decode(GroupSummary.self, sbd.sb(["group", "add", "--json", name] + sessions))
  }

  func groupList(_ sbd: Instance) throws -> GroupList { try decode(GroupList.self, sbd.sb("group", "ls", "--json")) }

  /// Arguments of a spawn on a new branch named `name` in a new repo.
  func spawnArgs(_ sbd: Instance, _ name: String) throws -> [String: JSON] {
    ["repository": .string(try sbd.makeRepo()), "branch": .string(name), "name": .string(name), "prompt": "hello"]
  }

  /// The text of each message that reached the session.
  func sent(_ sbd: Instance, _ id: String) throws -> [String] {
    try sbd.events(id).filter { $0.kind == "sent" }.compactMap { $0.data["text"]?.string }
  }

  /// A session whose first turn has ended with a reply.
  func idle(_ sbd: Instance, name: String) throws -> SessionSummary {
    let s = try sbd.new(prompt: "hello", name: name)
    try sbd.waitFor(s.id, "the first reply") { $0.lastReply == "Done: hello" }
    return s
  }

  func triaged(_ sbd: Instance) throws -> [String] {
    try sbd.client.call("triage", as: [SessionSummary].self).map(\.id)
  }

  /// The id of the card that a `send_group` call with text opens.
  func openPending(_ mcp: MCPClient, _ args: [String: JSON] = ["group": "Flags", "text": "Rebase on main."]) throws
    -> Int64
  {
    try #require(try mcp.call("send_group", args).decode(GroupSend.self).pending)
  }

  func scope(_ sbd: Instance) throws -> Scope {
    let member = try sbd.new(name: "member")
    let outside = try sbd.new(name: "outside")
    let loose = try sbd.new(name: "loose")
    return Scope(
      group: try addGroup(sbd, "Flags", member.id), other: try addGroup(sbd, "Billing", outside.id), member: member,
      outside: outside, loose: loose)
  }

  func name(_ id: String, _ name: String, _ how: Naming) -> String {
    switch how {
    case .id: id
    case .idPrefix: String(id.prefix(4))
    case .name: name
    }
  }
}
