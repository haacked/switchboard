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
  /// The card that the session wrote with `sb summary set` during its turn.
  case session
  /// An attention reason that a PR rule, a wait, or a follow-up gave.
  case rule
  /// A Haiku summary of the turn's last reply.
  case summary
  /// The last paragraph of the reply, because no summary exists.
  case fallback
}

/// What a click on an option does. Each one runs a request that sbd already
/// has, so a card adds no power that sb lacks.
public enum TriageAction: String, Codable, Sendable, CaseIterable {
  /// Sends the option's message to the session.
  case send
  /// Sends the text that the user types to the session.
  case reply
  /// Merges the session's PR, as `sb merge` does.
  case merge
  /// Acknowledges the Ready to merge item, as `sb merge --dismiss` does.
  case dismiss
  /// Requests a review of the session's PR from the reviewers that the user picks.
  case requestReview
  /// Sets the option's wait on the session.
  case wait
  /// Marks the session done.
  case done
  /// Allows the session's held permission prompt.
  case allow
  /// Denies the session's held permission prompt.
  case deny
  /// Allows the session's held permission prompt and switches the session to auto mode.
  case allowAutoMode
  /// Answers the session's held question with the option's message.
  case answer

  /// Whether the action runs `sb merge`, which also acknowledges.
  public var isMerge: Bool { self == .merge || self == .dismiss }

  /// Whether a click waits on gh for up to two minutes, so the app runs it
  /// apart from its other actions. The switch has no default, so a new
  /// action must state whether it waits on gh.
  public var waitsOnGh: Bool {
    switch self {
    case .merge, .requestReview: true
    case .send, .reply, .dismiss, .wait, .done, .allow, .deny, .allowAutoMode, .answer: false
    }
  }

  /// Whether the action acts on the PR for the user, as `sb merge` and
  /// `sb review` do, so a session may not run it. The switch has no
  /// default, so a new action must state whether it needs a click.
  public var needsClick: Bool {
    switch self {
    case .merge, .dismiss, .requestReview: true
    case .send, .reply, .wait, .done, .allow, .deny, .allowAutoMode, .answer: false
    }
  }

  /// The actions that a card from a session or the model may name. sbd adds
  /// the others to the cards that it builds from a held prompt or a PR.
  public static let writable: [TriageAction] = [.send, .reply, .merge, .wait, .done]
}

/// A choice that the user clicks.
public struct TriageOption: Codable, Equatable, Sendable {
  public var label: String
  public var detail: String?
  public var action: TriageAction
  /// The text that a `send` option sends, or the label that an `answer`
  /// option gives the card.
  public var message: String?
  public var recommended: Bool
  /// The wait that a `wait` option sets.
  public var wait: WaitRequest?
  /// The hint in a `reply` option's empty text field.
  public var placeholder: String?

  public init(
    label: String, detail: String? = nil, action: TriageAction = .send, message: String? = nil,
    recommended: Bool = false, wait: WaitRequest? = nil, placeholder: String? = nil
  ) {
    self.label = label
    self.detail = detail
    self.action = action
    self.message = message
    self.recommended = recommended
    self.wait = wait
    self.placeholder = placeholder
  }

  /// What a click on the option does, in one line, which a button shows
  /// because a click sends text as the user. A merge in a repository with a
  /// queue adds the PR to that queue.
  public func effect(mergeMethod: MergeMethod?) -> String {
    switch action {
    case .send: return "Sends: \(oneLine(message ?? label, max: 200))"
    case .reply: return "Sends the text you type"
    case .merge: return mergeMethod?.enqueues == true ? "Adds the PR to its merge queue" : "Merges the PR"
    case .dismiss: return "Hides the merge card until the PR gets a new commit or a new turn starts"
    case .requestReview: return "Requests a review from the reviewers you pick"
    case .wait: return "Waits on \(wait?.kind ?? "manual")\(wait?.target.map { " \($0)" } ?? "")"
    case .done: return "Marks the session done"
    case .allow: return "Allows the prompt"
    case .allowAutoMode: return "Allows the prompt and switches the session to auto mode"
    case .deny: return "Denies the prompt"
    case .answer: return "Answers: \(oneLine(message ?? label, max: 200))"
    }
  }

  /// Whether a multi-select card shows the option with a checkbox. Only
  /// messages and answers combine into one reply.
  public var isCheckable: Bool { action == .send || action == .answer }

  /// A `triage` event recorded before options had actions holds `send`
  /// options.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    label = try c.decode(String.self, forKey: .label)
    detail = try c.decodeIfPresent(String.self, forKey: .detail)
    action = try c.decodeIfPresent(TriageAction.self, forKey: .action) ?? .send
    message = try c.decodeIfPresent(String.self, forKey: .message)
    recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
    wait = try c.decodeIfPresent(WaitRequest.self, forKey: .wait)
    placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
  }
}

/// Something the user should read before deciding, such as a conflict, a
/// failed check, or a call that the session made without asking.
public struct Callout: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case warning
    case decision
    case info
  }

  public var kind: Kind
  public var title: String
  public var body: String

  public init(kind: Kind, title: String, body: String = "") {
    self.kind = kind
    self.title = title
    self.body = body
  }
}

/// What a session's card or Haiku's summary says about a turn.
public struct TriageSummary: Codable, Equatable, Sendable {
  public var title: String
  public var kind: TriageKind
  public var summary: String
  public var options: [TriageOption]
  public var callouts: [Callout]
  /// The user ticks any of the options and submits them as one reply.
  public var multiSelect: Bool
  /// The separate decisions that the reply asks for, each with its own options.
  public var decisions: [PendingDecision]

  public init(
    title: String, kind: TriageKind, summary: String, options: [TriageOption] = [], callouts: [Callout] = [],
    multiSelect: Bool = false, decisions: [PendingDecision] = []
  ) {
    self.title = title
    self.kind = kind
    self.summary = summary
    self.options = options
    self.callouts = callouts
    self.multiSelect = multiSelect
    self.decisions = decisions
  }

  /// A `triage` event recorded before cards had callouts, multiSelect, or
  /// decisions holds none and a single-choice card.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    title = try c.decode(String.self, forKey: .title)
    kind = try c.decode(TriageKind.self, forKey: .kind)
    summary = try c.decode(String.self, forKey: .summary)
    options = try c.decodeIfPresent([TriageOption].self, forKey: .options) ?? []
    callouts = try c.decodeIfPresent([Callout].self, forKey: .callouts) ?? []
    multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
    decisions = try c.decodeIfPresent([PendingDecision].self, forKey: .decisions) ?? []
  }
}

/// One entry of the triage list: what the session needs from the user.
public struct TriageItem: Codable, Equatable, Sendable {
  /// What the user does, in under 60 characters.
  public var title: String
  public var kind: TriageKind
  public var summary: String
  public var options: [TriageOption]
  /// What the user should read before deciding.
  public var callouts: [Callout]
  /// The user ticks any of the checkable options and submits them as one reply.
  public var multiSelect: Bool
  /// The separate decisions that the item asks for. While a decision list is
  /// open, they are the list's copy.
  public var decisions: [PendingDecision]
  public var source: TriageSource
  /// What the user can open after the Summary and the Action. The builder
  /// fills in the card's parts. The service adds the session's fields,
  /// because the builder sees only the session's facts.
  public var details: TriageDetails
  /// Names what the item is about: its card, or the turn that its reply
  /// ended. `choose` refuses a ref that is no longer the session's, so a
  /// click never lands on an item the user did not see.
  public var ref: String

  public init(
    title: String, kind: TriageKind, summary: String, options: [TriageOption] = [], callouts: [Callout] = [],
    multiSelect: Bool = false, decisions: [PendingDecision] = [], source: TriageSource, ref: String = "",
    details: TriageDetails = TriageDetails()
  ) {
    self.ref = ref
    self.details = details
    self.title = title
    self.kind = kind
    self.summary = summary
    self.options = options
    self.callouts = callouts
    self.multiSelect = multiSelect
    self.decisions = decisions
    self.source = source
  }

  init(_ summary: TriageSummary, source: TriageSource, ref: String = "") {
    self.init(
      title: summary.title, kind: summary.kind, summary: summary.summary, options: summary.options,
      callouts: summary.callouts, multiSelect: summary.multiSelect, decisions: summary.decisions, source: source,
      ref: ref)
  }

  private enum CodingKeys: String, CodingKey {
    case title, kind, summary, options, callouts, multiSelect, decisions, source, ref, message
  }

  private struct Sections: Decodable { var details: TriageDetails? }

  /// An item that an older sbd wrote has no multiSelect, decisions, or message.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    details = try c.decodeIfPresent(Sections.self, forKey: .message)?.details ?? TriageDetails()
    title = try c.decode(String.self, forKey: .title)
    kind = try c.decode(TriageKind.self, forKey: .kind)
    summary = try c.decode(String.self, forKey: .summary)
    options = try c.decode([TriageOption].self, forKey: .options)
    callouts = try c.decode([Callout].self, forKey: .callouts)
    multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
    decisions = try c.decodeIfPresent([PendingDecision].self, forKey: .decisions) ?? []
    source = try c.decode(TriageSource.self, forKey: .source)
    ref = try c.decode(String.self, forKey: .ref)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(title, forKey: .title)
    try c.encode(kind, forKey: .kind)
    try c.encode(summary, forKey: .summary)
    try c.encode(options, forKey: .options)
    try c.encode(callouts, forKey: .callouts)
    try c.encode(multiSelect, forKey: .multiSelect)
    try c.encode(decisions, forKey: .decisions)
    try c.encode(source, forKey: .source)
    try c.encode(ref, forKey: .ref)
    try c.encode(message, forKey: .message)
  }

  /// Whether the user ticks the option rather than clicks it.
  public func isTickable(_ option: TriageOption) -> Bool { multiSelect && option.isCheckable }

  /// The options that the keys name, in the options' order and each once.
  /// Every one must be tickable on a multi-select item.
  public func picks(_ keys: [String]) throws -> [TriageOption] {
    guard multiSelect else { throw APIError("the card takes one option. Name one") }
    let keys = keys.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard !keys.isEmpty else { throw APIError("name at least one option, by number or label") }
    var numbers = Set<Int>()
    for key in keys {
      let chosen = try option(key)
      guard isTickable(chosen) else {
        throw APIError("\"\(chosen.label)\" runs on its own and can't be picked with other options")
      }
      // A label written twice names its first option.
      numbers.insert(options.firstIndex(of: chosen)!)
    }
    return numbers.sorted().map { options[$0] }
  }

  /// The option that the card's main button runs: the recommended one, or
  /// the only one.
  public var primary: TriageOption? {
    options.first(where: \.recommended) ?? (options.count == 1 ? options.first : nil)
  }

  /// The index of the main option. An option written twice is one main option.
  public var primaryIndex: Int? { primary.flatMap { options.firstIndex(of: $0) } }

  /// Whether the user ticks some of the options and submits them together.
  public var hasTickable: Bool { options.contains(where: isTickable) }

  /// The option that `sb choose` and a click name: a 1-based number, or a
  /// label without regard to case.
  public func option(_ key: String) throws -> TriageOption {
    options[try optionIndex(key, labels: options.map(\.label))]
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
  /// Keeps the summary of the turn that ended at the last Stop, and the card
  /// that the session wrote during its current turn. A failed or skipped
  /// summary, and a summary for any other turn, leave none. A new prompt
  /// starts a newer turn, which drops both.
  mutating func applyTriage(_ event: Event) {
    switch event.kind {
    case "Stop":
      lastStop = event.id
      triage = nil
    case "UserPromptSubmit":
      // A summary of the earlier turn that arrives later keys to no turn.
      lastStop = 0
      triage = nil
      sessionSummary = nil
      sessionSummaryId = 0
    case Triage.sessionEvent:
      guard let card = try? JSONCoding.convert(event.data, to: TriageSummary.self) else { return }
      sessionSummary = card
      sessionSummaryId = event.id
    case "triage":
      if event.data["skipped"] == nil {
        summaryCalls = summaryCalls.filter { event.t - $0 < AutoContinue.hourMs } + [event.t]
      }
      guard lastStop != 0, event.data["stop"]?.int.map(Int64.init) == lastStop, event.data["error"] == nil,
        event.data["skipped"] == nil
      else { return }
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
  /// The kind of the event that `sb summary set` records.
  public static let sessionEvent = "summary"

  /// The session's item, or nil when it needs nothing from the user.
  /// `verdict` is the session's attention verdict. An open decision list
  /// puts its stored decisions on the item, so a later card or rule doesn't
  /// replace the answers. A held prompt's item keeps none, because the
  /// prompt needs its own answer first.
  public static func item(_ facts: SessionFacts, _ verdict: Verdict) -> TriageItem? {
    item(facts, live: liveItem(facts, verdict))
  }

  /// The session's item, its open decision list, and whether a submit sent
  /// the item's decisions, all from one live item.
  public static func itemAndDecisions(_ facts: SessionFacts, _ verdict: Verdict) -> (
    item: TriageItem?, decisions: DecisionList?, decisionsSent: Bool
  ) {
    let live = liveItem(facts, verdict)
    return (item(facts, live: live), decisionList(facts, live: live), decisionsSent(facts, live: live))
  }

  private static func item(_ facts: SessionFacts, live: TriageItem?) -> TriageItem? {
    guard var item = live else { return nil }
    if let list = facts.decisionList, item.source != .card { item.decisions = list.decisions }
    return item
  }

  /// The open decision list, with the decisions of a later item in `newer`.
  private static func decisionList(_ facts: SessionFacts, live: TriageItem?) -> DecisionList? {
    guard var list = facts.decisionList else { return nil }
    if let live, live.ref != list.ref { list.newer = live.decisions }
    return list
  }

  /// Whether the last accepted submit sent the decisions of the session's
  /// item. The item keeps them until the session's next prompt lands, and
  /// they don't open again.
  private static func decisionsSent(_ facts: SessionFacts, live: TriageItem?) -> Bool {
    guard facts.decisionList == nil, let sent = facts.submittedDecisionsRef, let live else { return false }
    return live.ref == sent && live.hasDecisionList
  }

  /// The item that the session's card, summary, rule, or reply gives.
  static func liveItem(_ facts: SessionFacts, _ verdict: Verdict) -> TriageItem? {
    guard AttentionState.inbox.contains(verdict.state) else { return nil }
    var item: TriageItem
    if let card = facts.cards.first {
      item = cardItem(card)
      item.ref = card.ref
    } else if let own = facts.sessionSummary, facts.openPermission == nil, facts.openQuestion == nil {
      item = TriageItem(own, source: .session, ref: "summary:\(facts.sessionSummaryId)")
      if verdict.source != .reply { addRule(verdict, to: &item) }
    } else if !fromReply(facts, verdict) {
      item = ruleItem(verdict)
      item.ref = "rule:\(item.title)"
    } else {
      item = facts.triage.map { TriageItem($0, source: .summary) } ?? fallbackItem(facts.lastReply ?? "", verdict)
      item.ref = "stop:\(facts.lastStop)"
    }
    return item
  }

  /// Adds what a rule found after the session wrote its card. The rule's
  /// reason and callouts come before the card's callouts. The rule's options
  /// come after the card's options, except an action the card already offers.
  /// The card's main option stays the main option.
  static func addRule(_ verdict: Verdict, to item: inout TriageItem) {
    let kind: Callout.Kind = verdict.state == .needsYou ? .warning : .info
    item.callouts.insert(contentsOf: [Callout(kind: kind, title: title(verdict.reason))] + verdict.callouts, at: 0)
    let lead = item.primary
    let added = verdict.options.filter { rule in
      !item.options.contains { $0.action == rule.action && ($0.action != .send || $0.message == rule.message) }
    }
    item.options += added.map { option in
      var option = option
      if lead != nil { option.recommended = false }
      return option
    }
    if let lead, let i = item.options.firstIndex(of: lead) { item.options[i].recommended = true }
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
          TriageOption(label: "Send", action: .allow),
          TriageOption(label: "Cancel", action: .deny),
        ], source: .card,
        details: TriageDetails(
          openByDefault: true, toolInput: .init(tool: card.tool, text: message.text),
          targets: message.targets.map { "\($0.name) (\($0.id))" }))
    }
    if card.kind == .permission {
      return TriageItem(
        title: title(card.reason), kind: .approval, summary: permissionSummary(card),
        options: [
          TriageOption(label: "Allow", action: .allow, recommended: true),
          TriageOption(label: "Deny", action: .deny),
        ] + (card.offersAutoMode ? [TriageOption(label: PermissionMode.approveLabel, action: .allowAutoMode)] : []),
        source: .card,
        details: TriageDetails(
          openByDefault: !summaryShowsCall(card), toolInput: .init(tool: card.tool, text: card.details)))
    }
    // Several questions take more than a click or a set of ticks.
    let only = card.questions.count == 1 ? card.questions.first : nil
    let options = (only?.options ?? []).map {
      TriageOption(label: $0.label, detail: $0.description, action: .answer, message: $0.label)
    }
    return TriageItem(
      title: title(card.reason), kind: .question,
      summary: card.questions.map(\.question).joined(separator: " "), options: options,
      multiSelect: only?.multiSelect ?? false, source: .card)
  }

  static func ruleItem(_ verdict: Verdict) -> TriageItem {
    let text = capitalized(verdict.reason)
    return TriageItem(
      title: title(verdict.reason), kind: verdict.kind,
      summary: verdict.summary ?? (text.hasSuffix(".") ? text : text + "."),
      options: verdict.options, callouts: verdict.callouts, source: .rule)
  }

  /// The reply's closing section as the summary, with no options.
  static func fallbackItem(_ reply: String, _ verdict: Verdict) -> TriageItem {
    let kind: TriageKind
    switch Attention.classify(reply) {
    case .question: kind = .question
    case .offer: kind = .approval
    case .other: kind = .info
    }
    return TriageItem(title: title(verdict.reason), kind: kind, summary: closingSection(reply), source: .fallback)
  }

  /// A fallback summary lists at most this many items of a list.
  static let closingItems = TriageSummarizer.maxDecisions

  /// The reply's last list when at most one paragraph follows it: the line
  /// before the list, a line for each item, and that paragraph. Otherwise the
  /// reply's last paragraph. Every word comes from the reply, so a list of
  /// changes reads as the reply wrote it and not as a list of decisions.
  static func closingSection(_ reply: String) -> String {
    let lastParagraph = Attention.lastParagraph(reply) ?? ""
    let blocks = MarkdownBlock.parse(reply)
    guard let at = blocks.lastIndex(where: { if case .list = $0 { true } else { false } }),
      case .list(let number, let items) = blocks[at]
    else { return lastParagraph }
    var closing: String?
    switch blocks[(at + 1)...].first {
    case nil: break
    case .paragraph(let text) where at + 2 == blocks.count: closing = text.plain
    default: return lastParagraph
    }
    let itemLines = items.prefix(closingItems).enumerated().compactMap { i, item -> String? in
      guard case .paragraph(let text) = item.blocks.first else { return nil }
      let box = item.checked.map { $0 ? "[x] " : "[ ] " } ?? ""
      let marker = (number.map { "\($0 + i). " } ?? "- ") + box
      return oneLine(marker + itemLine(text.plain), max: TriageCard.lineLength)
    }
    guard !itemLines.isEmpty else { return lastParagraph }
    let lead: String? =
      switch at > 0 ? blocks[at - 1] : nil {
      case .paragraph(let text): text.plain.components(separatedBy: "\n").last
      case .heading(_, let text): text.plain
      default: nil
      }
    let lines =
      [lead.map { oneLine($0, max: TriageCard.lineLength) }] + itemLines
      + [items.count > closingItems ? "…" : nil, closing]
    return lines.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
  }

  /// A list item on one line. An item that names a recommendation keeps its
  /// first sentence and the first sentence that recommends.
  static func itemLine(_ text: String) -> String {
    let line = oneLine(text, max: .max)
    guard line.localizedCaseInsensitiveContains("recommend") else { return line }
    // A list item can start with a flag such as --squash. The text has no markup left, so the split trims only
    // whitespace.
    let sentences = Attention.sentences(line, trimming: .whitespaces)
    guard let pick = sentences.dropFirst().first(where: { $0.localizedCaseInsensitiveContains("recommend") }) else {
      return line
    }
    return sentences[0] + " " + pick
  }

  /// A reason line as a title: its first letter capitalized, and the first
  /// "; " a colon.
  static func title(_ reason: String) -> String {
    let text = capitalized(reason).replacingOccurrences(of: "; ", with: ": ")
    return oneLine(text, max: titleLength)
  }

  /// The picks as one option, whose message is the one reply that they send.
  /// `picks` is not empty.
  public static func combined(_ picks: [TriageOption]) -> TriageOption {
    var option = picks[0]
    option.message = message(for: picks)
    return option
  }

  /// The one reply that a multi-select card's picks send. Answers name
  /// their labels separated by commas, as `Card.match` reads them. Messages
  /// go one per line as a list, or alone for a single pick.
  public static func message(for picks: [TriageOption]) -> String {
    let texts = picks.map { $0.message ?? $0.label }
    if picks.first?.action == .answer { return texts.joined(separator: ", ") }
    return texts.count == 1 ? texts[0] : texts.map { "- \($0)" }.joined(separator: "\n")
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

  /// Whether the session needs the user and counts toward the Inbox and the badge.
  public static func needsYou(_ s: SessionSummary) -> Bool { s.state.needsUser && mayHaveItem(s) }

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
  /// The most summary calls for one session in any hour.
  public var perHour = 6
  /// Goes to every claude as `--append-system-prompt`. Empty turns it off.
  public var systemPrompt =
    "When you need the user to choose between options, ask with the AskUserQuestion tool instead of asking in prose. Put the option you recommend first. The exception is a turn that ends with three or more separate decisions for the user: list them in your reply, then write them with `sb summary set` and its decisions field, and don't call AskUserQuestion. Don't write decisions for a list of work you finished. `sb summary help` shows the format."

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = TriageSettings()
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
    account = try c.decodeIfPresent(String.self, forKey: .account)
    timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
    perHour = try c.decodeIfPresent(Int.self, forKey: .perHour) ?? d.perHour
    systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? d.systemPrompt
  }
}

extension Card {
  /// The ref of the Inbox item that this card gives.
  public var ref: String { "card:\(id)" }
}
