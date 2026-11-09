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

  public init(
    decisions: [PendingDecision], ref: String, answers: [DecisionAnswer] = [], stale: Bool = false,
    newer: [PendingDecision] = []
  ) {
    self.decisions = decisions
    self.ref = ref
    self.answers = answers
    self.stale = stale
    self.newer = newer
  }

  public func answer(_ number: Int) -> DecisionAnswer? { answers.first { $0.number == number } }

  /// The numbers of the decisions without an answer.
  public var unanswered: [Int] { decisions.map(\.number).filter { answer($0) == nil } }

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
  /// The decision events build the open list. None of them changes the
  /// verdict. A new prompt makes the open list stale.
  mutating func applyDecisions(_ event: Event) {
    switch event.kind {
    case "decisions_opened":
      guard let ref = event.data["ref"]?.string, let raw = event.data["decisions"],
        let decisions = try? JSONCoding.convert(raw, to: [PendingDecision].self)
      else { return }
      decisionList = DecisionList(decisions: decisions, ref: ref)
    case "decision_answered":
      guard let answer = try? JSONCoding.convert(event.data, to: DecisionAnswer.self), answer.isValid else { return }
      decisionList?.record(answer)
    case "decisions_submitted":
      submittedDecisionsRef = event.data["ref"]?.string
      submittedDecisionsMessage = event.data["message"]?.string
      decisionsDelivery = DecisionsDelivery(Delivery(of: event))
      decisionList = nil
    case "decisions_discarded":
      decisionList = nil
    case "UserPromptSubmit":
      decisionList?.stale = true
    default:
      break
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
