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
      _ = try wait.makeWait(id: "w", waiter: "", now: now) { Wait.SessionTarget(id: $0, name: $0) }
      option.wait = wait
    default:
      break
    }
    return option
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
  public static let instructions = """
    At the end of a turn that needs the user, write the Inbox card for it:

      sb summary set <<'EOF'
      {"summary": "...", "options": [...], "callouts": [...]}
      EOF

    summary   Required. Two to three lines separated by "\\n", each under \(lineLength) characters: what you did,
              then what you need from the user. Write only what the user needs to understand the options
              and pick one. The full reply stays in the card's Details, so don't repeat it.
    title     Optional. Under \(Triage.titleLength) characters, what the user does ("Pick how to land #98").
              It defaults to the summary's first line.
    options   Up to \(maxOptions) options, each with a label (a short verb phrase such as "Fix + merge", under
              \(labelLength) characters) and an action:
                send    sends "message" to you as the user's reply, so write it as the user would say it
                        ("Yes, push."). Without "message" it sends the label.
                reply   shows a text field; the user's text comes to you ("placeholder" is its hint)
                merge   merges your PR, as `sb merge` does, once it is ready to merge
                wait    sets the wait in "wait", such as {"kind": "ci", "target": "98"} (see `sb help`)
                done    marks you done
              "recommended": true makes an option the main one. "detail" says what the option does, in a
              line under its label.
              Give exactly one option when the next step is obvious. Otherwise give one option per real
              choice, recommend at most one, and leave out filler such as Cancel or Skip.
    multiSelect  Optional. "multiSelect": true lets the user tick any of the options and submit them at
              once, when several choices apply together, such as which review items to fix. Every option
              must then be a send option. A single pick sends its message, and several send one message
              that lists each picked option's message on its own line.
    decisions Optional. Use it in place of "options" when the turn ends with two or more separate decisions
              for the user, each with its own options. Still write the summary.
              Up to \(TriageSummarizer.maxDecisions) decisions, each with:
                number      the decision's number in your reply, from 1, each one different. When your reply
                            doesn't number its decisions, use each one's position.
                header      under \(PendingDecision.headerLength) characters, such as "Name" or "Storage"
                question    under \(PendingDecision.questionLength) characters
                context     optional, under \(PendingDecision.contextLength) characters: why it matters, from your reply
                options     \(PendingDecision.minOptions) to \(PendingDecision.maxOptions), each with a "label" (under \(labelLength) characters, each
                            different), an optional "detail" (under \(PendingDecision.detailLength) characters), and
                            "recommended": true on at most one
                multiSelect optional, true when the user may pick several options
              The user answers each decision with an option, typed text, or a skip, and Switchboard sends
              you one message that answers them all in order.
    drafts    Optional. Messages you wrote for the user to send to someone else, such as a review request, a
              Slack message, a PR comment, or an email, up to \(TriageDrafts.maxDrafts). Each is a string, or an object
              with "text" and a short "label" ("Review request to HogQL"). The text is the message itself, in
              Markdown, without quote markers or code fences. The Inbox shows each draft in full with a copy
              button, so the summary only says that it is ready. Leave drafts out when the message is not for
              someone else, such as a commit message you will use yourself.
              A reply to a comment, a review, or a conversation comment on your PR also takes "replyTo": the
              comment's html_url from `gh api`, copied as is, at most \(TriageDrafts.replyToLength) characters. It ends in
              #discussion_r<id>, #r<id>, #issuecomment-<id>, or #pullrequestreview-<id>. Leave replyTo out when
              you don't have that URL: the draft then only has a copy button. Switchboard checks the URL with gh,
              and the user posts the reply from the Inbox. Don't post the reply yourself.
    callouts  Optional, and most cards have none. Up to \(maxCallouts) things the user must read before deciding that
              the summary doesn't already say: a conflict, a failing check, a risk, a call you made
              without asking, a destructive step. Each has "kind" (warning, decision, or info), "title"
              (under \(labelLength) characters), and "body" (a sentence or two).

    Example, with one obvious next step:

      sb summary set <<'EOF'
      {"title": "Push haacked/fix-retry",
       "summary": "Fixed the retry loop and added a test.\\nThe tests pass, and the branch is ready to push.",
       "options": [{"label": "Push", "action": "send", "message": "Yes, push.", "recommended": true}]}
      EOF

    Example, with two decisions:

      sb summary set <<'EOF'
      {"title": "Pick a name and a ship date",
       "summary": "Wrote the CLI and its tests.\\nIt needs a name and a ship date.",
       "decisions": [
         {"number": 1, "header": "Name", "question": "Should the app be Switchboard or Hub?",
          "options": [{"label": "Switchboard", "recommended": true}, {"label": "Hub"}]},
         {"number": 2, "header": "Ship it now", "question": "Should I ship the CLI now?",
          "options": [{"label": "Yes", "recommended": true}, {"label": "No", "detail": "Wait for the app"}]}]}
      EOF

    Example, with a reply for the user to post on your PR:

      sb summary set <<'EOF'
      {"summary": "Fixed the NOT handling that ann asked about.\\nThe reply to her comment is ready to post.",
       "drafts": [{"label": "Reply to ann", "text": "Good catch, fixed in abc123.",
                   "replyTo": "https://github.com/acme/widgets/pull/42#discussion_r2512345678"}]}
      EOF

    sbd shows the card until your next turn starts. It drops an option, a decision, or a callout that doesn't fit this
    format and prints why, so fix the card and run the command again. Nothing in the card runs: each button
    only runs its action.
    """
}
