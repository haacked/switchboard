import Foundation

/// Reads the card that a session writes with `sb summary set`, or that the
/// model writes for a turn. Every field is text from the session, so this
/// only keeps it: an option names an action from a fixed set, and nothing in
/// the card runs.
public enum TriageCard {
  public static let summaryLines = 4
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
  /// its message. A nil `kind` takes the kind from the options.
  public static func clean(
    _ raw: JSON, actions: [TriageAction] = TriageAction.writable, kind: TriageKind? = nil, now: Int64 = 0
  ) throws -> Cleaned {
    guard raw.object != nil else { throw APIError("the summary is a JSON object") }
    let lines = (raw["summary"]?.string ?? "").split(whereSeparator: \.isNewline)
      .map { oneLine(String($0), max: lineLength) }.filter { !$0.isEmpty }
    guard let first = lines.first else { throw APIError("the summary needs a summary") }
    var dropped: [String] = []
    if lines.count > summaryLines { dropped.append("lines after the first \(summaryLines) of the summary") }
    let options = keep(raw["options"], "option", max: maxOptions, &dropped) {
      try option($0, actions: actions, now: now)
    }
    let callouts = keep(raw["callouts"], "callout", max: maxCallouts, &dropped) { try callout($0) }
    let title = oneLine(raw["title"]?.string ?? "", max: Triage.titleLength)
    let card = TriageSummary(
      title: title.isEmpty ? oneLine(first, max: Triage.titleLength) : title,
      kind: kind ?? self.kind(for: options),
      summary: lines.prefix(summaryLines).joined(separator: "\n"), options: options, callouts: callouts)
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
        let label = value["label"]?.string.map { "\"\(oneLine($0, max: 40))\"" } ?? "\(i + 1)"
        dropped.append("\(name) \(label): \(error)")
      }
    }
    if kept.count > max {
      dropped.append("\(name)s after the first \(max)")
      kept = Array(kept.prefix(max))
    }
    return kept
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
      _ = try wait.makeWait(id: "w", waiter: "", now: now) { Wait.SessionTarget(id: $0, name: $0) }
      option.wait = wait
    default:
      break
    }
    return option
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
  public static let instructions = """
    At the end of a turn that needs the user, write the Inbox card for it:

      sb summary set <<'EOF'
      {"summary": "...", "options": [...], "callouts": [...]}
      EOF

    summary   Required. Two to four lines separated by "\\n", each under 200 characters: what you did,
              then what you need from the user.
    title     Optional. Under 60 characters, what the user does ("Pick how to land #98").
              It defaults to the summary's first line.
    options   Up to 6 buttons, each with a label (under 80 characters) and an action:
                send    sends "message" to you as the user's reply, so write it as the user would say it
                        ("Yes, push."). Without "message" it sends the label.
                reply   shows a text field; the user's text comes to you ("placeholder" is its hint)
                merge   merges your PR, as `sb merge` does, once it is ready to merge
                wait    sets the wait in "wait", such as {"kind": "ci", "target": "98"} (see `sb help`)
                done    marks you done
              "recommended": true makes an option the main button. "detail" adds a line under the label.
              Give exactly one option when the next step is obvious. Otherwise give one option per real
              choice, recommend at most one, and leave out filler such as Cancel or Skip.
    callouts  Optional, and most cards have none. Up to 5 things the user must read before deciding that
              the summary doesn't already say: a conflict, a failing check, a risk, a call you made
              without asking, a destructive step. Each has "kind" (warning, decision, or info), "title"
              (under 80 characters), and "body" (a sentence or two).

    Example, with one obvious next step:

      sb summary set <<'EOF'
      {"title": "Push haacked/fix-retry",
       "summary": "Fixed the retry loop and added a test.\\nThe tests pass, and the branch is ready to push.",
       "options": [{"label": "Push", "action": "send", "message": "Yes, push.", "recommended": true}]}
      EOF

    sbd shows the card until your next turn starts. It drops an option or a callout that doesn't fit this
    format and prints why, so fix the card and run the command again. Nothing in the card runs: each button
    only runs its action.
    """
}
