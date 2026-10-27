import Foundation

/// A permission prompt or a question that the main session waits on, which
/// the user can answer without opening the session.
public struct Card: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable {
    case permission
    case question
  }

  /// The id of the PermissionRequest event that opened the card.
  public var id: Int64
  public var session: String
  public var kind: Kind
  public var tool: String
  /// The tool call in words, or the first question.
  public var summary: String
  public var input: JSON
  /// An AskUserQuestion call's questions. A permission card has none.
  public var questions: [Question]
  /// Milliseconds since the epoch.
  public var since: Int64
  /// sbd denied the held request so that claude could stop. The answer goes
  /// to the session as a message.
  public var deferred: Bool

  /// How long a PermissionRequest hook waits for its card's answer before
  /// Claude Code closes it.
  public static let holdSeconds = 86_400

  /// The message that a deferred question's hook answers with.
  public static let deferMessage =
    "Switchboard recorded your question and shows it to the user. End your turn now. The answer arrives as your next message."

  init(_ event: Event) {
    let call = Attention.call(event.data["tool_name"]?.string ?? "", event.data, event.t)
    id = event.id
    session = event.session
    kind = call.tool == "AskUserQuestion" ? .question : .permission
    tool = call.tool
    input = call.input ?? [:]
    questions = kind == .question ? Question.parse(input) : []
    summary = call.summary
    since = call.since
    deferred = false
  }

  /// Whether a tool call is this card's. A question pairs by tool alone,
  /// because its answers change its input.
  func isCall(_ tool: String, _ input: JSON?) -> Bool {
    self.tool == tool && (kind == .question || self.input == input)
  }

  /// Each answer as the label it names, one per question. An answer names a
  /// label regardless of case. A multi-select answer names labels separated
  /// by commas. Text that names no label stays as typed.
  public func match(_ answers: [String]) throws -> [String] {
    guard answers.count == questions.count else {
      throw APIError("the card has \(questions.count) questions, and the answer has \(answers.count)")
    }
    return try zip(questions, answers).map { q, answer in
      let text = answer.trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { throw APIError("answer \"\(q.question)\"") }
      func label(_ s: String) -> String {
        q.options.first { $0.label.caseInsensitiveCompare(s) == .orderedSame }?.label ?? s
      }
      guard q.multiSelect else { return label(text) }
      return text.split(separator: ",").map { label($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: ", ")
    }
  }

  /// Allows the question with the answers in its input.
  public func decision(answers: [String]) -> Decision {
    var updated = input.object ?? [:]
    updated["answers"] = .object(Dictionary(zip(questions.map(\.question), answers.map(JSON.string))) { a, _ in a })
    return .allow(updatedInput: .object(updated))
  }

  /// The message that brings the answers to a session whose question was
  /// deferred.
  public func answerMessage(_ answers: [String]) -> String {
    zip(questions, answers).map { "Answer to your question \"\($0.question)\": \($1)" }.joined(separator: "\n")
  }
}

/// One question of an AskUserQuestion call.
public struct Question: Codable, Equatable, Sendable {
  public struct Option: Codable, Equatable, Sendable {
    public var label: String
    public var description: String?

    public init(label: String, description: String? = nil) {
      self.label = label
      self.description = description
    }
  }

  public var question: String
  /// The short label that Claude Code shows in a chip above the question.
  public var header: String?
  public var options: [Option]
  public var multiSelect: Bool

  public init(question: String, header: String?, options: [Option], multiSelect: Bool) {
    self.question = question
    self.header = header
    self.options = options
    self.multiSelect = multiSelect
  }

  static func parse(_ input: JSON) -> [Question] {
    (input["questions"]?.array ?? []).compactMap { q in
      guard let text = q["question"]?.string else { return nil }
      let options = (q["options"]?.array ?? []).compactMap { o in
        o["label"]?.string.map { Option(label: $0, description: o["description"]?.string) }
      }
      return Question(
        question: text, header: q["header"]?.string, options: options, multiSelect: q["multiSelect"]?.bool ?? false)
    }
  }
}

/// A held PermissionRequest's answer.
public enum Decision: Equatable, Sendable {
  case allow(updatedInput: JSON?)
  /// Claude reads the message and goes on. Without a message, the turn stops,
  /// as No does in the terminal.
  case deny(message: String?)

  /// What the hook prints for Claude Code.
  public var hookOutput: JSON {
    var decision: [String: JSON]
    switch self {
    case .allow(let input):
      decision = ["behavior": "allow"]
      if let input { decision["updatedInput"] = input }
    case .deny(let message?):
      decision = ["behavior": "deny", "message": .string(message)]
    case .deny(nil):
      decision = ["behavior": "deny", "interrupt": true]
    }
    return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": .object(decision)]]
  }
}

extension SessionFacts {
  /// Opens, closes, and defers cards. The table in the answer cards plan
  /// lists what each event does.
  mutating func applyCards(_ event: Event) {
    let d = event.data
    let tool = d["tool_name"]?.string ?? ""
    let card = d["card"]?.int.flatMap { id in cards.firstIndex { $0.id == Int64(id) } }
    switch event.kind {
    case "PermissionRequest" where d["agent_id"] == nil:
      cards.append(Card(event))
    case "PostToolUse" where d["agent_id"] == nil, "PostToolUseFailure" where d["agent_id"] == nil:
      cards.removeAll { !$0.deferred && $0.isCall(tool, d["tool_input"]) }
    case "answered":
      guard let card else { return }
      let answered = cards.remove(at: card)
      closePrompt(answered)
      guard d["behavior"]?.string == "deny" else { return }
      if d["message"]?.string == nil {
        endTurn()
      } else if let running = runningTool, answered.isCall(running.tool, running.input) {
        runningTool = nil
      }
    case "deferred":
      guard let card else { return }
      cards[card].deferred = true
      closePrompt(cards[card])
    case "card_closed":
      // A hook that timed out closes too. Claude Code's dialog then stays
      // open, so the prompt stays open until the idle prompt that follows No
      // or Escape.
      guard let card else { return }
      cards.remove(at: card)
    case "Stop", "StopFailure", "SessionEnd", "stopped", "exited",
      "Notification" where d["notification_type"]?.string == "idle_prompt":
      cards.removeAll { !$0.deferred }
    case "UserPromptSubmit":
      let fromUser = !Attention.isSubagentResult(d["prompt"]?.string ?? "")
      cards.removeAll { fromUser || !$0.deferred }
    default:
      break
    }
  }

  private mutating func closePrompt(_ card: Card) {
    if card.kind == .question {
      openQuestion = nil
    } else if let open = openPermission, card.isCall(open.tool, open.input) {
      openPermission = nil
    }
  }
}
