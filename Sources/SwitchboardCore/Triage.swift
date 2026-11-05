import Foundation

public enum TriageKind: String, Codable, Sendable {
  case decision
  case question
  case approval
  case review
  case action
  case info
}

/// Where an item's text came from.
public enum TriageSource: String, Codable, Sendable {
  /// A held permission prompt or `AskUserQuestion` call.
  case card
  /// An attention reason that a PR rule, a wait, or a follow-up gave.
  case rule
  /// A Haiku summary of the turn's last reply.
  case summary
  /// The last paragraph of the reply, because no summary exists.
  case fallback
}

/// A choice that the user clicks. For a `card` item, `message` is the answer
/// that `choose` gives the card: `allow` or `deny` for a permission prompt, and
/// the option's label for a question. For other items it is the text that the
/// session receives.
public struct TriageOption: Codable, Equatable, Sendable {
  public var label: String
  public var detail: String?
  public var message: String
  public var recommended: Bool

  public init(label: String, detail: String? = nil, message: String, recommended: Bool = false) {
    self.label = label
    self.detail = detail
    self.message = message
    self.recommended = recommended
  }
}

/// What Haiku says about a turn that ended in prose.
public struct TriageSummary: Codable, Equatable, Sendable {
  public var title: String
  public var kind: TriageKind
  public var summary: String
  public var options: [TriageOption]

  public init(title: String, kind: TriageKind, summary: String, options: [TriageOption] = []) {
    self.title = title
    self.kind = kind
    self.summary = summary
    self.options = options
  }
}

/// One entry of the triage list: what the session needs from the user.
public struct TriageItem: Codable, Equatable, Sendable {
  /// What the user does, in under 60 characters.
  public var title: String
  public var kind: TriageKind
  public var summary: String
  public var options: [TriageOption]
  public var source: TriageSource
  /// Names what the item is about: its card, or the turn that its reply
  /// ended. `choose` refuses a ref that is no longer the session's, so a
  /// click never lands on an item the user did not see.
  public var ref: String

  public init(
    title: String, kind: TriageKind, summary: String, options: [TriageOption] = [], source: TriageSource,
    ref: String = ""
  ) {
    self.ref = ref
    self.title = title
    self.kind = kind
    self.summary = summary
    self.options = options
    self.source = source
  }

  /// The option that `sb choose` and a click name: a 1-based number, or a
  /// label without regard to case.
  public func option(_ key: String) throws -> TriageOption {
    let key = key.trimmingCharacters(in: .whitespaces)
    if let n = Int(key) {
      guard n > 0, options.indices.contains(n - 1) else {
        throw APIError("there is no option \(n). There are \(options.count)")
      }
      return options[n - 1]
    }
    let matches = options.filter { $0.label.caseInsensitiveCompare(key) == .orderedSame }
    guard matches.count == 1 else {
      let labels = options.map(\.label).joined(separator: ", ")
      throw APIError(
        matches.isEmpty
          ? "no option \"\(key)\". The options are: \(labels)" : "\"\(key)\" names \(matches.count) options")
    }
    return matches[0]
  }
}

extension Attention {
  /// The verdict for a turn that ended with no card, rule, or wait to decide
  /// the session's state.
  public static func replyVerdict(_ reply: String) -> Verdict {
    switch classify(reply) {
    case .question(let q): return Verdict(state: .needsYou, reason: oneLine("answer: \(q)"), source: .reply)
    case .offer(let o): return Verdict(state: .canContinue, reason: oneLine("offered: \(o)"), source: .reply)
    case .other: return Verdict(state: .needsYou, reason: "read its last reply and decide what's next", source: .reply)
    }
  }
}

extension SessionFacts {
  /// Keeps the summary of the turn that ended at the last Stop. A summary
  /// for any other turn, a failed one, and a new prompt leave none.
  mutating func applyTriage(_ event: Event) {
    switch event.kind {
    case "Stop":
      lastStop = event.id
      triage = nil
    case "UserPromptSubmit":
      // A summary of the earlier turn that arrives later keys to no turn.
      lastStop = 0
      triage = nil
    case "triage":
      guard lastStop != 0, event.data["stop"]?.int.map(Int64.init) == lastStop, event.data["error"] == nil else {
        return
      }
      triage = try? JSONCoding.convert(event.data, to: TriageSummary.self)
    default:
      break
    }
  }
}

/// The triage list: one item for each session that needs the user or that
/// Claude can continue, and the order the list shows them in.
public enum Triage {
  public static let titleLength = 60

  /// The session's item, or nil when it needs nothing from the user.
  /// `verdict` is the session's attention verdict.
  public static func item(_ facts: SessionFacts, _ verdict: Verdict) -> TriageItem? {
    guard AttentionState.inbox.contains(verdict.state) else { return nil }
    var item: TriageItem
    if let card = facts.cards.first {
      item = cardItem(card)
      item.ref = "card:\(card.id)"
    } else if !fromReply(facts, verdict) {
      item = ruleItem(verdict)
      item.ref = "rule:\(item.title)"
    } else {
      if let summary = facts.triage {
        item = TriageItem(
          title: oneLine(summary.title, max: titleLength), kind: summary.kind, summary: summary.summary,
          options: summary.options, source: .summary)
      } else {
        item = fallbackItem(facts.lastReply ?? "", verdict)
      }
      item.ref = "stop:\(facts.lastStop)"
    }
    return item
  }

  /// Whether the verdict is the one that the session's last reply gives, and
  /// no card, prompt, or rule decided it.
  static func fromReply(_ facts: SessionFacts, _ verdict: Verdict) -> Bool {
    facts.cards.isEmpty && facts.openPermission == nil && facts.openQuestion == nil && verdict.source == .reply
  }

  /// Whether the turn that just ended needs a summary: the reply decides the
  /// session's state, and no summary exists yet.
  public static func needsSummary(_ facts: SessionFacts, _ verdict: Verdict) -> Bool {
    facts.lastStop != 0 && facts.triage == nil && !(facts.lastReply ?? "").isEmpty
      && AttentionState.inbox.contains(verdict.state) && fromReply(facts, verdict)
  }

  static func cardItem(_ card: Card) -> TriageItem {
    if let message = card.send {
      return TriageItem(
        title: title(card.reason), kind: .approval,
        summary: "Claude asks to send \(message.summary). Nothing is sent until you send it.",
        options: [
          TriageOption(label: "Send", message: "allow"),
          TriageOption(label: "Cancel", message: "deny"),
        ], source: .card)
    }
    if card.kind == .permission {
      return TriageItem(
        title: title(card.reason), kind: .approval, summary: "Claude asks to run \(card.summary).",
        options: [
          TriageOption(label: "Allow", message: "allow", recommended: true),
          TriageOption(label: "Deny", message: "deny"),
        ], source: .card)
    }
    let first = card.questions.first
    // Several questions, or a multi-select one, take more than a click.
    let options =
      card.questions.count == 1 && first?.multiSelect == false
      ? (first?.options ?? []).map { TriageOption(label: $0.label, detail: $0.description, message: $0.label) } : []
    return TriageItem(
      title: title(card.reason), kind: .question,
      summary: card.questions.map(\.question).joined(separator: " "), options: options, source: .card)
  }

  static func ruleItem(_ verdict: Verdict) -> TriageItem {
    let text = capitalized(verdict.reason)
    return TriageItem(
      title: title(verdict.reason), kind: verdict.kind, summary: text.hasSuffix(".") ? text : text + ".",
      source: .rule)
  }

  /// The last paragraph of the reply as the summary, with no options.
  static func fallbackItem(_ reply: String, _ verdict: Verdict) -> TriageItem {
    let paragraphs = reply.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let kind: TriageKind
    switch Attention.classify(reply) {
    case .question: kind = .question
    case .offer: kind = .approval
    case .other: kind = .info
    }
    return TriageItem(
      title: title(verdict.reason), kind: kind, summary: paragraphs.last ?? "", source: .fallback)
  }

  /// A reason line as a title: its first letter capitalized, and the first
  /// "; " a colon.
  static func title(_ reason: String) -> String {
    let text = capitalized(reason).replacingOccurrences(of: "; ", with: ": ")
    return oneLine(text, max: titleLength)
  }

  public static func capitalized(_ text: String) -> String {
    text.prefix(1).uppercased() + text.dropFirst()
  }

  // MARK: Order

  /// The list's groups, first to last: a held prompt or question; a decision,
  /// question, or approval that a summary found; PR actions; finished work
  /// to review; and what Claude can continue.
  static func rank(_ s: SessionSummary) -> Int? {
    guard let item = s.triage else { return nil }
    if s.state == .canContinue { return 4 }
    if item.source == .card { return 0 }
    switch item.kind {
    case .decision, .question, .approval: return 1
    case .action: return 2
    case .review, .info: return 3
    }
  }

  /// Whether the session may put an item in the Inbox, the badge, the menu
  /// bar, a notification, or Next Needing You. The Manager and the group chats
  /// may not, because their replies and cards repeat or name the sessions they
  /// manage, which have their own entries. Nothing reports a problem with sb
  /// itself, such as an out-of-date sbd. This refuses every item of theirs.
  public static func mayHaveItem(_ s: SessionSummary) -> Bool { s.kind == .work }

  /// The sessions that have an item, by group and then oldest first.
  public static func order(_ sessions: [SessionSummary]) -> [SessionSummary] {
    var ranked: [(session: SessionSummary, rank: Int)] = []
    for s in sessions where mayHaveItem(s) {
      if let r = rank(s) { ranked.append((s, r)) }
    }
    ranked.sort { a, b in
      if a.rank != b.rank { return a.rank < b.rank }
      if a.session.since != b.session.since { return a.session.since < b.session.since }
      return a.session.id < b.session.id
    }
    return ranked.map(\.session)
  }
}

/// The `triage` object of config.json.
public struct TriageSettings: Codable, Equatable, Sendable {
  /// Turns the summaries off. The nudge below stays.
  public var enabled = true
  /// The model of the summary call.
  public var model = "haiku"
  /// The Claude config folder that the summary call runs under, or nil for
  /// the session's own account.
  public var account: String?
  /// How long a summary call may run before sbd ends it.
  public var timeoutSeconds = 60.0
  /// Goes to every claude as `--append-system-prompt`. Empty turns it off.
  public var systemPrompt =
    "When you need the user to choose between options, ask with the AskUserQuestion tool instead of asking in prose. Put the option you recommend first."

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = TriageSettings()
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
    account = try c.decodeIfPresent(String.self, forKey: .account)
    timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
    systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? d.systemPrompt
  }
}
