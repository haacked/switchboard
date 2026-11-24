import Foundation

/// A Manager conversation is an interactive session that manages the others
/// through `sb`. Every conversation shares one folder and its CLAUDE.md.
public enum Manager {
  public static let name = "Manager"
  /// The name of a conversation that started without a name or a prompt,
  /// until its first prompt names it.
  public static let untitled = "New conversation"
  static let maxNameLength = 40

  /// Orders conversations newest activity first, as `sb manager ls` and the sidebar list them.
  public static func newestFirst(_ a: SessionSummary, _ b: SessionSummary) -> Bool {
    (a.lastActivity, a.created ?? 0) > (b.lastActivity, b.created ?? 0)
  }

  /// The first non-empty line of the prompt, cut to 40 characters. A line that is the operator's
  /// name gives `untitled`, because the operator's name belongs to the operator alone.
  public static func name(fromPrompt prompt: String) -> String {
    guard let line = firstLine(prompt).map({ String($0.prefix(maxNameLength)) }), line != operatorName else {
      return untitled
    }
    return line
  }

  /// Names a conversation's MCP servers for the user. `nil` is the full setup.
  public static func serversText(_ servers: [String]?) -> String {
    guard let servers else { return "every MCP server (the full setup)" }
    return servers.isEmpty ? "switchboard only" : "switchboard, " + servers.joined(separator: ", ")
  }

  /// The fixed name of the operator, which no prompt renames.
  public static let operatorName = "Operator"

  /// The operator's role. sbd appends it to the system prompt at every launch, so it survives a resume and a
  /// compaction. The operator also reads the conversations' CLAUDE.md, because it shares their folder.
  public static var operatorPrompt: String { Prompts.text(.operatorRole) }

  /// What sbd appends to a Manager conversation's system prompt in place of `triage.systemPrompt`. The session view
  /// shows an AskUserQuestion call as a card. The rest of the triage prompt is about Inbox cards, which a
  /// conversation's turns never get.
  public static let conversationPrompt = TriageSettings.choiceGuidance

  /// What `sb manager mcp` and the server menu say while a change waits for claude to relaunch.
  public static let relaunchPendingText = "Claude restarts with them when its turn ends."

  /// The CLAUDE.md that sbd keeps in the Manager's folder. It is a prompt for
  /// a model, so it stays short, and every `sb` command in it exists.
  public static var guide: String { Prompts.text(.managerGuide) }
}

/// sbd's answer to `manager-mcp`.
public struct ManagerMCPAnswer: Codable, Equatable, Sendable {
  public var session: String
  public var name: String
  /// The servers besides switchboard, or nil for the full setup. It encodes nil as null.
  public var servers: [String]?
  /// The servers that a list can name.
  public var available: [String]
  /// True until claude relaunches with the stored servers.
  public var pending: Bool

  public init(session: String, name: String, servers: [String]?, available: [String], pending: Bool) {
    self.session = session
    self.name = name
    self.servers = servers
    self.available = available
    self.pending = pending
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(session, forKey: .session)
    try container.encode(name, forKey: .name)
    try container.encode(servers, forKey: .servers)
    try container.encode(available, forKey: .available)
    try container.encode(pending, forKey: .pending)
  }
}
