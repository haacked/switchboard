import Foundation

/// What an Inbox item holds beyond its Summary and its Action: the facts
/// that the user opens only when the Summary leaves a question. Each part is
/// left out of the JSON when the item has none.
public struct TriageDetails: Codable, Equatable, Sendable {
  /// The call that a held prompt or a group message asks about, in full.
  public struct ToolInput: Codable, Equatable, Sendable {
    public var tool: String
    public var text: String

    public init(tool: String, text: String) {
      self.tool = tool
      self.text = text
    }
  }

  public struct PR: Codable, Equatable, Sendable {
    public var line: String
    public var title: String
    public var url: String

    public init(line: String, title: String, url: String) {
      self.line = line
      self.title = title
      self.url = url
    }
  }

  /// Whether the app opens Details at first. It is true for a permission
  /// prompt whose Summary does not show the whole call, so the user never
  /// allows a call that the Inbox shows in part.
  public var openByDefault: Bool
  public var lastReply: String?
  public var toolInput: ToolInput?
  public var pullRequest: PR?
  public var waits: [String]
  public var notes: [String]
  /// The sessions that a group message goes to, as `name (id)`.
  public var targets: [String]

  /// The names of the parts that this item has, in the order the app lists them.
  public var parts: [String] {
    var parts: [String] = []
    if toolInput != nil { parts.append("tool input") }
    if !targets.isEmpty { parts.append("targets") }
    if pullRequest != nil { parts.append("pull request") }
    if !waits.isEmpty { parts.append("waits") }
    if !notes.isEmpty { parts.append("notes") }
    if lastReply != nil { parts.append("last reply") }
    return parts
  }

  public init(
    openByDefault: Bool = false, lastReply: String? = nil, toolInput: ToolInput? = nil, pullRequest: PR? = nil,
    waits: [String] = [], notes: [String] = [], targets: [String] = []
  ) {
    self.openByDefault = openByDefault
    self.lastReply = lastReply
    self.toolInput = toolInput
    self.pullRequest = pullRequest
    self.waits = waits
    self.notes = notes
    self.targets = targets
  }

  private enum CodingKeys: String, CodingKey {
    case openByDefault, lastReply, toolInput, pullRequest, waits, notes, targets
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    openByDefault = try c.decodeIfPresent(Bool.self, forKey: .openByDefault) ?? false
    lastReply = try c.decodeIfPresent(String.self, forKey: .lastReply)
    toolInput = try c.decodeIfPresent(ToolInput.self, forKey: .toolInput)
    pullRequest = try c.decodeIfPresent(PR.self, forKey: .pullRequest)
    waits = try c.decodeIfPresent([String].self, forKey: .waits) ?? []
    notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    targets = try c.decodeIfPresent([String].self, forKey: .targets) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(openByDefault, forKey: .openByDefault)
    try c.encodeIfPresent(lastReply, forKey: .lastReply)
    try c.encodeIfPresent(toolInput, forKey: .toolInput)
    try c.encodeIfPresent(pullRequest, forKey: .pullRequest)
    if !waits.isEmpty { try c.encode(waits, forKey: .waits) }
    if !notes.isEmpty { try c.encode(notes, forKey: .notes) }
    if !targets.isEmpty { try c.encode(targets, forKey: .targets) }
  }
}

/// An Inbox item as three sections, always in this order: the Summary, the
/// Action, and the Details. `sb ls --json`, `sb get --json`, `sb triage
/// --json`, and the MCP `triage` tool carry it as `triage.message`. It
/// repeats the item's own fields, which stay for the scripts that read them.
public struct TriageMessage: Codable, Equatable, Sendable {
  /// The context that the user needs to understand the options.
  public struct Summary: Codable, Equatable, Sendable {
    public var text: String
    public var callouts: [Callout]
  }

  /// The buttons.
  public struct Action: Codable, Equatable, Sendable {
    public var options: [TriageOption]
    public var multiSelect: Bool
    /// The index of the main option, or nil when no option is the main one.
    public var primary: Int?

    private enum CodingKeys: String, CodingKey { case options, multiSelect, primary }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(options, forKey: .options)
      try c.encode(multiSelect, forKey: .multiSelect)
      try c.encode(primary, forKey: .primary)
    }
  }

  public var summary: Summary
  public var action: Action
  public var details: TriageDetails
}

extension TriageItem {
  public var message: TriageMessage {
    TriageMessage(
      summary: .init(text: summary, callouts: callouts),
      action: .init(options: options, multiSelect: multiSelect, primary: primaryIndex), details: details)
  }
}

extension Triage {
  /// The call in the Summary of a permission prompt. A Bash command shows
  /// whole when it fits on one line, and cut at one line otherwise.
  static func callSummary(_ card: Card) -> String {
    guard card.tool == "Bash", let command = card.input["command"]?.string else { return card.summary }
    return "`\(oneLine(command, max: TriageCard.lineLength))`"
  }

  /// Whether the Summary of a permission prompt shows its whole call.
  static func summaryShowsCall(_ card: Card) -> Bool {
    guard card.tool == "Bash", let command = card.input["command"]?.string else { return false }
    return command.count <= TriageCard.lineLength && !command.contains(where: \.isNewline)
  }

  /// The item's Details, from the session's own fields. The item builder
  /// has only the session's facts, which hold neither its waits nor its notes.
  public static func details(for s: SessionSummary) -> TriageDetails {
    var details = TriageDetails()
    details.lastReply = (s.lastReply ?? "").isEmpty ? nil : s.lastReply
    details.pullRequest = s.pr.map { TriageDetails.PR(line: $0.line, title: $0.title, url: $0.url) }
    details.waits = s.waits.map(\.line)
    details.notes = s.notes.map(\.text)
    if s.triage?.source == .card, let card = s.cards.first {
      if let message = card.send {
        details.toolInput = .init(tool: card.tool, text: message.text)
        details.targets = message.targets.map { "\($0.name) (\($0.id))" }
      } else if card.kind == .permission {
        details.toolInput = .init(tool: card.tool, text: card.details)
        details.openByDefault = !summaryShowsCall(card)
      }
    }
    return details
  }
}
