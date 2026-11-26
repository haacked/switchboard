import Foundation

/// MCP servers that a Manager conversation asked for. The request waits for
/// the user's decision in the app, because a new server widens what the
/// conversation can do, and the conversation reads text that can quote PR
/// comments and logs.
public struct MCPServerRequest: Codable, Equatable, Sendable {
  /// The servers to add, or nil for the full setup. It encodes nil as null.
  public var servers: [String]?
  /// Why the conversation asks, exactly as Claude wrote it. The app shows it and never interprets it.
  public var reason: String

  public init(servers: [String]?, reason: String) {
    self.servers = servers
    self.reason = reason
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(servers, forKey: .servers)
    try container.encode(reason, forKey: .reason)
  }

  /// What the request asks, in the words of the card's title.
  public var summary: String {
    guard let servers else { return "load every MCP server in this conversation" }
    return "add \(englishList(servers)) to this conversation"
  }

  /// What the card tells the user before they decide.
  public var effect: String {
    let connectors =
      servers == nil
      ? " The full setup includes claude.ai connectors such as Slack and every server in your config." : ""
    return
      "Claude restarts with the servers and resumes this conversation. Nothing changes until you allow it. Send the conversation a message after the restart to continue.\(connectors)"
  }
}

/// What became of an MCP server request.
public enum MCPRequestDecision: String, Codable, Sendable {
  case pending
  case allowed
  case denied
}

/// sbd's answer to `manager-mcp-request` and to an answer of its card.
public struct MCPServerRequestStatus: Codable, Equatable, Sendable {
  public var card: Int64
  public var session: String
  public var name: String
  /// The requested servers, or nil for the full setup. It encodes nil as null.
  public var servers: [String]?
  public var reason: String
  public var decision: MCPRequestDecision
  /// The conversation's servers besides switchboard when sbd answered, or nil for the full setup. It encodes
  /// nil as null.
  public var loaded: [String]?

  public init(
    card: Int64, session: String, name: String, request: MCPServerRequest, decision: MCPRequestDecision,
    loaded: [String]? = []
  ) {
    self.card = card
    self.session = session
    self.name = name
    self.servers = request.servers
    self.reason = request.reason
    self.decision = decision
    self.loaded = loaded
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(card, forKey: .card)
    try container.encode(session, forKey: .session)
    try container.encode(name, forKey: .name)
    try container.encode(servers, forKey: .servers)
    try container.encode(reason, forKey: .reason)
    try container.encode(decision, forKey: .decision)
    try container.encode(loaded, forKey: .loaded)
  }
}

extension Card {
  /// The card that an `mcp_request` event opens, or nil when its data isn't a request.
  public init?(mcpRequest event: Event) {
    guard let request = try? JSONCoding.convert(event.data, to: MCPServerRequest.self) else { return nil }
    self.init(decision: event, kind: .mcp, tool: "request_mcp_server", summary: request.summary)
    mcpRequest = request
  }
}
