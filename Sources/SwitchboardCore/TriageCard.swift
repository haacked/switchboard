import Foundation

/// Reads the card that a session writes with `sb summary set`, or that the
/// model writes for a turn. Every field is text from the session, so this
/// only keeps it: an option names an action from a fixed set, and nothing in
/// the card runs.
public enum TriageCard {
  public static let summaryLines = 3
  public static let lineLength = 200
  public static let maxOptions = 6
  public static let maxCallouts = 5
  public static let labelLength = 80
  public static let messageLength = 2_000
  public static let bodyLength = 1_000

  /// The card, and a line for each part that it drops, which says why.
  public struct Cleaned: Equatable, Sendable {
    public var card: TriageSummary
    public var dropped: [String]
  }

  /// Options may name only the `actions`. An option without an action sends
  /// its message. A nil `kind` takes the kind from the options. The summary
  /// keeps its first `lines` lines.
  public static func clean(
    _ raw: JSON, actions: [TriageAction] = TriageAction.writable, kind: TriageKind? = nil,
    lines maxLines: Int = summaryLines, now: Int64 = 0
  ) throws -> Cleaned {
    guard raw.object != nil else { throw APIError("the summary is a JSON object") }
    let lines = (raw["summary"]?.string ?? "").split(whereSeparator: \.isNewline)
      .map { oneLine(String($0), max: lineLength) }.filter { !$0.isEmpty }
    guard let first = lines.first else { throw APIError("the summary needs a summary") }
    var dropped: [String] = []
    if lines.count > maxLines { dropped.append("lines after the first \(maxLines) of the summary") }
    var multiSelect = raw["multiSelect"]?.bool ?? false
    var options = keep(raw["options"], "option", max: maxOptions, &dropped) {
      let option = try option($0, actions: actions, now: now)
      if multiSelect, option.action != .send {
        throw APIError("a multiSelect card's options all send a message, and this one is \(option.action.rawValue)")
      }
      return option
    }
    let callouts = keep(raw["callouts"], "callout", max: maxCallouts, &dropped) { try callout($0) }
    var numbers = Set<Int>()
    var decisions = keep(raw["decisions"], "decision", max: TriageSummarizer.maxDecisions, &dropped) {
      let decision = try decision($0)
      guard numbers.insert(decision.number).inserted else {
        throw APIError("another decision has the number \(decision.number)")
      }
      return decision
    }
    // One decision makes no list, so the app would show none of its options. They become the card's options.
    if decisions.count == 1, options.isEmpty, actions.contains(.send) {
      let lone = decisions.removeFirst()
      multiSelect = multiSelect || lone.multiSelect
      options = lone.options.map {
        TriageOption(label: $0.label, detail: $0.detail, action: .send, message: $0.label, recommended: $0.recommended)
      }
    }
    let drafts = TriageDrafts.read(raw["drafts"], &dropped)
    let title = oneLine(raw["title"]?.string ?? "", max: Triage.titleLength)
    let card = TriageSummary(
      title: title.isEmpty ? oneLine(first, max: Triage.titleLength) : title,
      kind: kind ?? (decisions.formList ? .decision : self.kind(for: options)),
      summary: lines.prefix(maxLines).joined(separator: "\n"), options: options, callouts: callouts,
      multiSelect: multiSelect, decisions: decisions, drafts: drafts)
    return Cleaned(card: card, dropped: dropped)
  }

  /// The first `max` elements of `list` that `parse` reads. Each element that
  /// fails or doesn't fit adds a line to `dropped`.
  static func keep<T>(
    _ list: JSON?, _ name: String, max: Int, _ dropped: inout [String], _ parse: (JSON) throws -> T
  ) -> [T] {
    var kept: [T] = []
    for (i, value) in (list?.array ?? []).enumerated() {
      do {
        kept.append(try parse(value))
      } catch {
        dropped.append(droppedLine(name, label: value["label"]?.string, index: i, error))
      }
    }
    if kept.count > max {
      dropped.append("\(name)s after the first \(max)")
      kept = Array(kept.prefix(max))
    }
    return kept
  }

  /// The line in `dropped` for the element at `index`, named by its label when it has one.
  static func droppedLine(_ name: String, label: String?, index: Int, _ error: Error) -> String {
    "\(name) \(label.map { "\"\(oneLine($0, max: 40))\"" } ?? "\(index + 1)"): \(error)"
  }

  /// A card with several options asks for a decision, and one with a single
  /// option asks for a yes. One without options is finished work to read.
  static func kind(for options: [TriageOption]) -> TriageKind {
    switch options.count {
    case 0: return .review
    case 1: return .approval
    default: return .decision
    }
  }

  static func option(_ raw: JSON, actions: [TriageAction], now: Int64) throws -> TriageOption {
    let label = oneLine(raw["label"]?.string ?? "", max: labelLength)
    guard !label.isEmpty else { throw APIError("it has no label") }
    let name: String
    if let value = raw["action"] {
      guard let text = value.string else { throw APIError("its action is not text") }
      name = text
    } else {
      name = TriageAction.send.rawValue
    }
    guard let action = TriageAction(rawValue: name), actions.contains(action) else {
      throw APIError("\"\(oneLine(name, max: 40))\" is not one of \(actions.map(\.rawValue).joined(separator: ", "))")
    }
    let detail = oneLine(raw["detail"]?.string ?? "", max: lineLength)
    var option = TriageOption(
      label: label, detail: detail.isEmpty ? nil : detail, action: action,
      recommended: raw["recommended"]?.bool ?? false)
    switch action {
    case .send:
      let message = String(
        (raw["message"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          .prefix(messageLength))
      option.message = message.isEmpty ? label : message
    case .reply:
      let placeholder = oneLine(raw["placeholder"]?.string ?? "", max: labelLength)
      option.placeholder = placeholder.isEmpty ? nil : placeholder
    case .wait:
      guard let value = raw["wait"], var wait = try? JSONCoding.convert(value, to: WaitRequest.self) else {
        throw APIError("a wait option needs a wait object, such as {\"kind\": \"ci\"}")
      }
      // The user's click sets the wait, so the session can't name its author.
      wait.by = nil
      // A session target is checked when the user clicks.
      let made = try wait.makeWait(id: "w", waiter: "", now: now) { Wait.SessionTarget(id: $0, name: $0) }
      if let action = made.action { throw armsAction(action.kind) }
      option.wait = wait
    default:
      break
    }
    return option
  }

  /// The refusal of a wait option that arms an action. The session or the model writes the option's label, which
  /// need not name the action. `choose` sets the wait from inside sbd, so sbd can't check who arms it.
  public static func armsAction(_ action: WaitAction.Kind) -> APIError {
    APIError(
      "a card's wait option can't take then \(action.rawValue), because only a Manager conversation, the Operator, "
        + "or you can arm an action, with `sb wait`")
  }

  /// A decision keeps the reply's number, so `sb decide` names it as the
  /// reply does. Its options' labels differ, so a label names one option.
  static func decision(_ raw: JSON) throws -> PendingDecision {
    typealias D = PendingDecision
    guard let number = raw["number"]?.int, number > 0 else { throw APIError("it needs a number of 1 or more") }
    let header = oneLine(raw["header"]?.string ?? "", max: D.headerLength)
    guard !header.isEmpty else { throw APIError("it has no header") }
    let question = oneLine(raw["question"]?.string ?? "", max: D.questionLength)
    guard !question.isEmpty else { throw APIError("it has no question") }
    let context = String(
      (raw["context"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(D.contextLength))
    let options = try (raw["options"]?.array ?? []).map { raw -> D.Option in
      let label = oneLine(raw["label"]?.string ?? "", max: labelLength)
      guard !label.isEmpty else { throw APIError("an option has no label") }
      let detail = oneLine(raw["detail"]?.string ?? "", max: D.detailLength)
      return D.Option(
        label: label, detail: detail.isEmpty ? nil : detail, recommended: raw["recommended"]?.bool ?? false)
    }
    guard (D.minOptions...D.maxOptions).contains(options.count) else {
      throw APIError("it has \(options.count) options, and a decision has \(D.minOptions) to \(D.maxOptions)")
    }
    guard options.filter(\.recommended).count <= 1 else { throw APIError("it recommends more than one option") }
    guard Set(options.map { $0.label.lowercased() }).count == options.count else {
      throw APIError("two of its options have the same label")
    }
    return D(
      number: number, header: header, question: question, context: context.isEmpty ? nil : context,
      options: options, multiSelect: raw["multiSelect"]?.bool ?? false)
  }

  static func callout(_ raw: JSON) throws -> Callout {
    let name = raw["kind"]?.string ?? ""
    guard let kind = Callout.Kind(rawValue: name) else {
      throw APIError(
        "\"\(oneLine(name, max: 40))\" is not one of \(Callout.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
    }
    let title = oneLine(raw["title"]?.string ?? "", max: labelLength)
    guard !title.isEmpty else { throw APIError("it has no title") }
    let body = String((raw["body"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(bodyLength))
    return Callout(kind: kind, title: title, body: body)
  }

  /// What `sb summary help` prints: how a session writes its card.
  public static var instructions: String { Prompts.text(.triageCard) }
}
