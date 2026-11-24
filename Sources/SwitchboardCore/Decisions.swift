import Foundation

/// One of several decisions that a reply asks the user to make, each with
/// its own options. The user can always type an answer instead.
public struct PendingDecision: Codable, Equatable, Sendable {
  public static let headerLength = 24
  public static let questionLength = 200
  public static let contextLength = 1_000
  public static let detailLength = 200
  public static let minOptions = 2
  public static let maxOptions = 5

  /// The reply's own number for the decision. `sb decide` names a decision by it.
  public var number: Int
  public var header: String
  public var question: String
  /// The reply's explanation of the decision.
  public var context: String?
  public var options: [Option]
  public var multiSelect: Bool

  public struct Option: Codable, Equatable, Sendable {
    public var label: String
    public var detail: String?
    public var recommended: Bool

    public init(label: String, detail: String? = nil, recommended: Bool = false) {
      self.label = label
      self.detail = detail
      self.recommended = recommended
    }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      label = try c.decode(String.self, forKey: .label)
      detail = try c.decodeIfPresent(String.self, forKey: .detail)
      recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
    }
  }

  public init(
    number: Int, header: String, question: String, context: String? = nil, options: [Option],
    multiSelect: Bool = false
  ) {
    self.number = number
    self.header = header
    self.question = question
    self.context = context
    self.options = options
    self.multiSelect = multiSelect
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    number = try c.decode(Int.self, forKey: .number)
    header = try c.decode(String.self, forKey: .header)
    question = try c.decode(String.self, forKey: .question)
    context = try c.decodeIfPresent(String.self, forKey: .context)
    options = try c.decode([Option].self, forKey: .options)
    multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
  }

  /// The labels of the options that the keys name, in the options' order and
  /// each once. A key is a 1-based number or a label without regard to case.
  public func labels(_ keys: [String]) throws -> [String] {
    let keys = keys.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !keys.isEmpty else { throw APIError("name an option of decision \(number), by number or label") }
    guard multiSelect || keys.count == 1 else { throw APIError("decision \(number) takes one option") }
    let labels = options.map(\.label)
    let picked = Set(try keys.map { try optionIndex($0, labels: labels) })
    return picked.sorted().map { labels[$0] }
  }
}

/// The user's answer to one decision, as a `decision_answered` event records
/// it. Exactly one of `labels`, `text`, and `skip` is set.
public struct DecisionAnswer: Codable, Equatable, Sendable {
  public var number: Int
  /// The picked options' labels.
  public var labels: [String]?
  /// A typed answer, which replaces any option.
  public var text: String?
  /// True when the user left the decision open.
  public var skip: Bool?

  public init(number: Int, labels: [String]? = nil, text: String? = nil, skip: Bool? = nil) {
    self.number = number
    self.labels = labels
    self.text = text
    self.skip = skip
  }

  public var isValid: Bool {
    [labels?.isEmpty == false, text?.isEmpty == false, skip == true].filter { $0 }.count == 1
  }
}

/// The decisions that the user answers one at a time before one Submit. sbd
/// keeps a copy of them from the first answer, so a later turn or rule
/// doesn't replace the answers.
public struct DecisionList: Codable, Equatable, Sendable {
  public static let skipText = "Not decided. Don't act on it yet. Ask me again later."

  public var decisions: [PendingDecision]
  /// The ref of the item that the decisions came from.
  public var ref: String
  /// The latest answer to each answered decision, in the decisions' order.
  public var answers: [DecisionAnswer]
  /// True once a turn started after the list opened.
  public var stale: Bool
  /// The decisions of a later item, which the open list keeps out of the Inbox.
  public var newer: [PendingDecision]
  /// The user's questions about single decisions, oldest first, each with the session's answer.
  public var exchanges: [DecisionExchange]

  public init(
    decisions: [PendingDecision], ref: String, answers: [DecisionAnswer] = [], stale: Bool = false,
    newer: [PendingDecision] = [], exchanges: [DecisionExchange] = []
  ) {
    self.decisions = decisions
    self.ref = ref
    self.answers = answers
    self.stale = stale
    self.newer = newer
    self.exchanges = exchanges
  }

  /// A list that an older sbd wrote has no exchanges.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    decisions = try c.decode([PendingDecision].self, forKey: .decisions)
    ref = try c.decode(String.self, forKey: .ref)
    answers = try c.decode([DecisionAnswer].self, forKey: .answers)
    stale = try c.decode(Bool.self, forKey: .stale)
    newer = try c.decode([PendingDecision].self, forKey: .newer)
    exchanges = try c.decodeIfPresent([DecisionExchange].self, forKey: .exchanges) ?? []
  }

  public func answer(_ number: Int) -> DecisionAnswer? { answers.first { $0.number == number } }

  /// The numbers of the decisions without an answer.
  public var unanswered: [Int] { decisions.map(\.number).filter { answer($0) == nil } }

  /// The decision whose question waits for its answer. sbd takes one question per session at a time.
  public var pendingAsk: Int? { exchanges.first(where: \.pending)?.number }

  /// Why sbd refuses to answer, submit, or discard the list, or nil. The pending question's reply can change the
  /// user's answers.
  public var pendingAskReason: String? {
    pendingAsk.map { "Wait for the answer to your question about decision \($0)" }
  }

  /// Ends the pending exchange of the ask with the session's reply or with an error.
  mutating func close(ask askId: String, reply: String? = nil, error: String? = nil) {
    guard let i = exchanges.firstIndex(where: { $0.askId == askId && $0.pending }) else { return }
    exchanges[i].pending = false
    exchanges[i].reply = reply
    exchanges[i].error = error
  }

  mutating func record(_ answer: DecisionAnswer) {
    guard decisions.contains(where: { $0.number == answer.number }) else { return }
    answers.removeAll { $0.number == answer.number }
    answers.append(answer)
    let order = decisions.map(\.number)
    answers.sort { order.firstIndex(of: $0.number)! < order.firstIndex(of: $1.number)! }
  }

  /// The one message that Submit sends: a lead line, then one line per
  /// decision in order. Nil while a decision has no answer.
  public var message: String? {
    guard unanswered.isEmpty else { return nil }
    let lines = decisions.map { d -> String in
      let question = d.question.hasSuffix("?") || d.question.hasSuffix(":") ? d.question : d.question + ":"
      return "\(d.number). \(question) \(Self.text(of: answer(d.number)!, for: d))"
    }
    return (["My decisions on the \(decisions.count) questions in your last reply:"] + lines).joined(separator: "\n")
  }

  /// The answer as the decision's line in the message says it. A skip reads
  /// as `skip`. Picked labels that match the recommendation get `recommended`
  /// after them, and with `period` they end with a period unless they already
  /// end a sentence.
  public static func text(
    of answer: DecisionAnswer, for decision: PendingDecision, skip: String = skipText,
    recommended suffix: String = " (your recommendation)", period: Bool = true
  ) -> String {
    if let text = answer.text { return text }
    guard let labels = answer.labels else { return skip }
    let recommended = decision.options.filter(\.recommended).map(\.label)
    var text = labels.joined(separator: ", ")
    if !recommended.isEmpty, labels == recommended { text += suffix }
    guard period else { return text }
    return text.last.map { ".!?".contains($0) } == true ? text : text + "."
  }
}

/// A question that the user asked the session about one decision of the open list, and how it ended.
public struct DecisionExchange: Codable, Equatable, Sendable {
  public var askId: String
  /// The number of the decision that the question is about.
  public var number: Int
  /// The user's question.
  public var text: String
  /// The last message of the turn that the question started.
  public var reply: String?
  /// Why the ask ended without a reply.
  public var error: String?
  /// True until the reply or an error arrives.
  public var pending: Bool

  public init(askId: String, number: Int, text: String, reply: String? = nil, error: String? = nil, pending: Bool) {
    self.askId = askId
    self.number = number
    self.text = text
    self.reply = reply
    self.error = error
    self.pending = pending
  }
}

/// The turn that a question about a decision starts: the turn of the next prompt that is the message sbd sent
/// for the ask. It ends at that turn's Stop.
public struct Clarifying: Codable, Equatable, Sendable {
  /// How far sbd got with the paste of the message.
  public enum Paste: String, Codable, Sendable {
    /// The message waits in the queue. A failed paste puts it back there.
    case waiting
    /// sbd recorded `pasting` and has not recorded the paste's result yet.
    case running
    /// sbd recorded `delivered`.
    case landed
  }

  public var askId: String
  public var number: Int
  /// The message that sbd sent for the ask.
  public var message: String
  /// True once claude reported the message as a prompt.
  public var started: Bool
  public var paste: Paste
  /// True when a prompt that is not the message arrived while the paste ran. When the paste then lands, that prompt
  /// held the message as the user changed it in the terminal.
  public var otherPromptDuringPaste: Bool
}

/// The data of a `decision_asked` event. `verdict` and `item` are what the session showed when the user asked.
public struct DecisionAsk: Codable, Equatable, Sendable {
  var ref: String
  var number: Int
  var askId: String
  var text: String
  var message: String
  var verdict: SavedVerdict
  var item: TriageItem

  public init(
    ref: String, number: Int, askId: String, text: String, message: String, verdict: SavedVerdict, item: TriageItem
  ) {
    self.ref = ref
    self.number = number
    self.askId = askId
    self.text = text
    self.message = message
    self.verdict = verdict
    self.item = item
  }

  public struct SavedVerdict: Codable, Equatable, Sendable {
    var state: AttentionState
    var reason: String

    public init(state: AttentionState, reason: String) {
      self.state = state
      self.reason = reason
    }
  }

  /// The message that sbd sends the session for a question about `decision`.
  public static func message(about decision: PendingDecision, _ text: String) -> String {
    "Question about decision \(decision.number) (\(decision.header)) in your last reply, before I decide: \(text)\n\n"
      + "Answer only this question, in text. Don't change files, run commands that change anything, or start work. "
      + "Don't write `sb summary set` or ask with AskUserQuestion this turn. "
      + "I'll send all my decisions together when I'm done."
  }
}

extension Array where Element == PendingDecision {
  /// Whether the decisions make a list that the user answers one at a time.
  /// A lone decision does not.
  public var formList: Bool { count > 1 }
}

extension TriageItem {
  public var hasDecisionList: Bool { decisions.formList }
}

extension SessionSummary {
  /// The list that the user answers: the open list, or the one that the
  /// first answer opens from the item. Nil when neither exists, and once sbd
  /// sent the answers to the item's decisions.
  public var shownDecisions: DecisionList? {
    if let decisions { return decisions }
    guard let item = triage, item.hasDecisionList, decisionsSent != true else { return nil }
    return DecisionList(decisions: item.decisions, ref: item.ref)
  }
}

extension SessionFacts {
  static let unansweredAsk = "The turn ended without an answer."
  static let undeliveredAsk = "The question never reached the session. Ask again."
  static let changedAsk = "The question changed before it reached the session. Ask again."
  static let unconfirmedAsk =
    "Switchboard can't tell whether your question reached the session. Ask again if no answer appears."

  /// The decision events build the open list. Only an ask changes the
  /// verdict, through `heldAsk`. A new prompt makes the open list stale,
  /// unless it starts the clarifying turn. `turnEnded` is true when the event
  /// ended the running turn.
  mutating func applyDecisions(_ event: Event, turnEnded: Bool) {
    if let ask = clarifying, ask.started, !event.fromSubagent, turnEnded || Self.endsTurn(event) {
      // A subagent's end of the turn leaves the ask open. The main session's own end of the turn closes it, and a
      // main Stop files its reply.
      let reply = event.kind == "Stop" ? event.data["last_assistant_message"]?.string ?? "" : ""
      endClarifying(reply: reply.isEmpty ? nil : reply, error: reply.isEmpty ? Self.unansweredAsk : nil)
    }
    switch event.kind {
    case "decisions_opened":
      guard let ref = event.data["ref"]?.string, let raw = event.data["decisions"],
        let decisions = try? JSONCoding.convert(raw, to: [PendingDecision].self)
      else { return }
      decisionList = DecisionList(decisions: decisions, ref: ref)
      clarifying = nil
    case "decision_answered":
      guard let answer = try? JSONCoding.convert(event.data, to: DecisionAnswer.self), answer.isValid else { return }
      decisionList?.record(answer)
    case "decisions_submitted":
      submittedDecisionsRef = event.data["ref"]?.string
      submittedDecisionsMessage = event.data["message"]?.string
      decisionsDelivery = DecisionsDelivery(Delivery(of: event))
      decisionList = nil
      clarifying = nil
    case "decisions_discarded":
      decisionList = nil
      clarifying = nil
    case "decision_asked":
      applyAsk(event)
    case "pasting", "delivered", "requeued":
      guard var ask = clarifying, !ask.started, event.data["text"]?.string == ask.message else { break }
      if event.kind == "delivered" && ask.otherPromptDuringPaste {
        endClarifying(error: Self.changedAsk)
        break
      }
      // A failed paste puts the message back in the queue, so a prompt during it did not hold the message.
      switch event.kind {
      case "pasting": ask.paste = .running
      case "delivered": ask.paste = .landed
      default: ask.paste = .waiting
      }
      ask.otherPromptDuringPaste = false
      clarifying = ask
    case "UserPromptSubmit":
      applyPromptToList(event.data["prompt"]?.string ?? "")
    case "SessionEnd", "stopped", "exited":
      // A claude that ends before the question's prompt arrived lost the question, and no prompt can start the
      // clarifying turn. A started ask is still open here only when a subagent ended the turn. Either pending ask
      // would refuse every change to the list for good.
      guard let ask = clarifying else { break }
      endClarifying(error: ask.started ? Self.unansweredAsk : Self.undeliveredAsk)
    case "delivery_unknown":
      // sbd restarted during the question's paste and found no sign of it in the transcript.
      guard let ask = clarifying, !ask.started, event.data["text"]?.string == ask.message else { break }
      endClarifying(error: Self.unconfirmedAsk)
    default:
      break
    }
    // The hold lasts while the list that the user asked from is open and fresh. After a submit of that list, it
    // lasts until the next prompt or a discard. The item then keeps the sent decisions that Resend needs.
    if let held = heldAsk {
      let open = decisionList.map { !$0.stale && $0.ref == held.ref } ?? false
      let sent =
        decisionList == nil && submittedDecisionsRef == held.ref && event.kind != "UserPromptSubmit"
        && event.kind != "decisions_discarded"
      if !open && !sent { heldAsk = nil }
    }
    guard let message = submittedDecisionsMessage, event.data["text"]?.string == message else { return }
    switch (event.kind, decisionsDelivery) {
    case ("delivered", .sending): decisionsDelivery = .delivered
    case ("delivery_unknown", .sending): decisionsDelivery = .unknown
    case ("sent", .unknown): decisionsDelivery = DecisionsDelivery(Delivery(of: event))
    default: break
    }
  }
}

extension SessionFacts {
  /// Whether the main session's event ends its turn. `turnEnded` is false for one that comes after a subagent's
  /// end of the turn, because that end already cleared `turnRunning`.
  private static func endsTurn(_ event: Event) -> Bool {
    switch event.kind {
    case "Stop", "StopFailure", "idle": true
    case "Notification": event.data["notification_type"]?.string == "idle_prompt"
    default: false
    }
  }

  /// Records an ask about a decision of the open, fresh list that the event names. An ask while another one is
  /// pending records nothing, because only one clarifying turn can be matched to its reply. The first ask of a
  /// hold saves the verdict and the item that the hold keeps.
  private mutating func applyAsk(_ event: Event) {
    guard clarifying == nil, let ask = try? JSONCoding.convert(event.data, to: DecisionAsk.self),
      let list = decisionList, list.ref == ask.ref, !list.stale
    else { return }
    if heldAsk == nil { heldAsk = Box(ask) }
    decisionList?.exchanges.append(
      DecisionExchange(askId: ask.askId, number: ask.number, text: ask.text, pending: true))
    clarifying = Clarifying(
      askId: ask.askId, number: ask.number, message: ask.message, started: false, paste: .waiting,
      otherPromptDuringPaste: false)
  }

  /// The prompt that is the ask's message starts the clarifying turn and leaves the list fresh. Any other prompt
  /// makes the list stale, and it ends a clarifying turn that never stopped with an error. After the paste landed,
  /// any other prompt also ends the unstarted ask with an error. Text that the user typed in the terminal while the
  /// paste ran changed the message into that prompt, so the message never arrives as its own prompt. A prompt while
  /// the paste runs ends the ask only when the paste then lands, because a failed paste puts the message back in the
  /// queue.
  private mutating func applyPromptToList(_ prompt: String) {
    if var ask = clarifying, !ask.started {
      if InboxRequest.isPrompt(prompt, of: ask.message) {
        ask.started = true
        ask.otherPromptDuringPaste = false
        clarifying = ask
        return
      }
      switch ask.paste {
      case .waiting: break
      case .running:
        ask.otherPromptDuringPaste = true
        clarifying = ask
      case .landed: endClarifying(error: Self.changedAsk)
      }
    } else if clarifying != nil {
      endClarifying(error: Self.unansweredAsk)
    }
    decisionList?.stale = true
  }

  /// Ends the pending ask with the session's reply or with an error.
  private mutating func endClarifying(reply: String? = nil, error: String? = nil) {
    guard let ask = clarifying else { return }
    decisionList?.close(ask: ask.askId, reply: reply, error: error)
    clarifying = nil
  }
}

/// Whether the message of a decisions submit reached claude.
public enum DecisionsDelivery: String, Codable, Sendable {
  /// sbd has not yet recorded that the paste succeeded.
  case sending
  case delivered
  /// sbd restarted while the paste ran, and the transcript doesn't show the message.
  case unknown

  /// The state of a message that `send` handled with `delivery`. A launch
  /// passes the message as claude's first prompt, so no paste follows. A
  /// submit from before sbd recorded the delivery counts as delivered,
  /// because that sbd recorded no `delivered` for a direct paste.
  init(_ delivery: Delivery?) {
    switch delivery {
    case .pasted, .queued: self = .sending
    case .resumed, nil: self = .delivered
    }
  }
}

/// The index of the option that `key` names: a 1-based number, or a label
/// without regard to case.
func optionIndex(_ key: String, labels: [String]) throws -> Int {
  let key = key.trimmingCharacters(in: .whitespaces)
  if let n = Int(key) {
    guard n > 0, labels.indices.contains(n - 1) else {
      throw APIError("there is no option \(n). There are \(labels.count)")
    }
    return n - 1
  }
  let matches = labels.indices.filter { labels[$0].caseInsensitiveCompare(key) == .orderedSame }
  guard matches.count == 1 else {
    throw APIError(
      matches.isEmpty
        ? "no option \"\(key)\". The options are: \(labels.joined(separator: ", "))"
        : "\"\(key)\" names \(matches.count) options")
  }
  return matches[0]
}
