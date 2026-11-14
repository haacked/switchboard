import Foundation

/// One of Claude's steps in a transcript: a text block or a tool call.
public struct TranscriptStep: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case text
    case tool
  }

  public var kind: Kind
  public var text: String?
  public var tool: String?
  /// The tool call on one line, which names the tool once.
  public var summary: String?
  /// The tool_use id.
  public var id: String?
  public var t: Int64?

  public init(
    kind: Kind, text: String? = nil, tool: String? = nil, summary: String? = nil, id: String? = nil,
    t: Int64? = nil
  ) {
    self.kind = kind
    self.text = text
    self.tool = tool
    self.summary = summary
    self.id = id
    self.t = t
  }
}

/// The place in a transcript that an Inbox item came from.
public enum TranscriptAnchor: Equatable, Sendable {
  /// The newest main-conversation call of `tool` with an equal input.
  case toolCall(tool: String, input: JSON)
  /// The newest assistant text equal to this reply, trimmed.
  case reply(String)
  /// The newest step.
  case end
  /// The item did not come from the conversation.
  case unanchored

  public var kind: ItemContext.Anchor {
    switch self {
    case .toolCall: .tool
    case .reply: .reply
    case .end: .end
    case .unanchored: .unanchored
    }
  }

  /// The anchor of the session's current item. A permission prompt or a
  /// question anchors at its call, which PermissionRequest names only by tool
  /// and input. This holds whether the prompt has a card or only a rule item.
  /// A reply item anchors at the reply that its summary came from. A session
  /// card belongs to the newest turn, because a new prompt drops it.
  public static func of(item: TriageItem?, facts: SessionFacts) -> TranscriptAnchor {
    guard let item else { return .end }
    switch item.source {
    case .card:
      guard let card = facts.cards.first(where: { $0.ref == item.ref }),
        card.kind == .permission || card.kind == .question
      else { return .unanchored }
      return .toolCall(tool: card.tool, input: card.input)
    case .session:
      return .end
    case .summary, .fallback:
      let reply = facts.lastReply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return reply.isEmpty ? .unanchored : .reply(reply)
    case .rule:
      return openPrompt(item, facts) ?? .unanchored
    }
  }

  /// The anchor of a rule item that is an open prompt without a card. A
  /// prompt that only a Notification reported names no call, so it anchors
  /// at the newest step.
  private static func openPrompt(_ item: TriageItem, _ facts: SessionFacts) -> TranscriptAnchor? {
    guard let open = Attention.openPromptVerdict(facts), item.ref == Triage.ruleRef(Triage.title(open.reason)),
      let call = facts.openPermission ?? facts.openQuestion
    else { return nil }
    if call.tool == Attention.notificationPromptTool { return .end }
    return .toolCall(tool: call.tool, input: call.input ?? [:])
  }
}

/// The steps of a session's transcript that lead up to its current item, as
/// the `item-context` request answers them.
public struct ItemContext: Codable, Equatable, Sendable {
  public enum Anchor: String, Codable, Sendable {
    case tool
    case reply
    case end
    case unanchored = "none"
  }

  /// The steps before the anchor that a read gets when it names no count.
  public static let defaultSteps = 5
  /// The most steps before the anchor that a read gets.
  public static let maxSteps = 200
  /// The most transcript bytes, from the end, that a read searches for its
  /// anchor once it holds the newest steps. A miss would otherwise read the
  /// whole file.
  public static let anchorSearchBytes = 8 << 20

  public var session: String
  /// The item's ref, or nil when the session has no item.
  public var ref: String?
  /// How sbd tried to anchor the steps.
  public var anchor: Anchor
  /// Whether the anchor was found. Then the last step is the anchor.
  public var anchored: Bool
  /// Whether older steps exist before the first one.
  public var more: Bool
  /// Oldest first.
  public var steps: [TranscriptStep]

  public init(session: String, ref: String?, anchor: Anchor, anchored: Bool, more: Bool, steps: [TranscriptStep]) {
    self.session = session
    self.ref = ref
    self.anchor = anchor
    self.anchored = anchored
    self.more = more
    self.steps = steps
  }

  /// The index of the anchor's step, or nil when the anchor was not found.
  public var anchorIndex: Int? { anchored ? steps.indices.last : nil }

  /// Why the steps are not tied to the item, or nil when they are.
  public var caption: String? {
    if anchored { return nil }
    return anchor == .unanchored
      ? "This item didn't come from the conversation."
      : "Not tied to this item: Switchboard couldn't find where it came from in the transcript."
  }
}

extension Transcript {
  /// The anchor's step and the `steps` steps before it, oldest first. A
  /// step is a text or tool_use block of an assistant line of the main
  /// conversation, as `message(_:)` keeps them. When the anchor is not found,
  /// or is `.unanchored`, these are the newest `steps` steps and `anchored`
  /// is false. The search for the anchor stops after `searchBytes` bytes
  /// from the end once the newest steps are read. When a read fails before
  /// the anchor is found, there are no steps.
  /// `more` is true when an older step exists before the first one.
  public static func context(
    _ path: String, anchor: TranscriptAnchor, steps: Int, searchBytes: Int = ItemContext.anchorSearchBytes,
    on machine: any Machine
  ) -> (steps: [TranscriptStep], anchored: Bool, more: Bool) {
    // Both lists are newest first. `newest` is the answer when the walk finds no anchor.
    var anchored: [TranscriptStep] = []
    var newest: [TranscriptStep] = []
    var found = false
    var more = false
    var newestMore = false
    var scanned = 0
    let complete = eachLineFromEnd(path, on: machine) { data in
      scanned += data.count
      if !found, anchor != .unanchored, newest.count >= steps, scanned > searchBytes {
        newestMore = true
        return true
      }
      guard let line = TranscriptLine(data), line.type == "assistant", line.isMainConversation else { return false }
      let t = line.timestamp
      let lastText = line.blocks.lastIndex { if case .text = $0 { true } else { false } }
      for index in line.blocks.indices.reversed() {
        guard let step = step(line.blocks[index], at: t) else { continue }
        if !found {
          if newest.count < steps { newest.append(step) } else { newestMore = true }
          found = anchor != .unanchored && matches(line, index, lastText: lastText, anchor)
          if !found { continue }
        } else if anchored.count > steps {
          more = true
          return true
        }
        anchored.append(step)
      }
      return anchor == .unanchored && newestMore
    }
    if found { return (anchored.reversed(), true, more) }
    return complete ? (newest.reversed(), false, newestMore) : ([], false, false)
  }

  /// Whether the line's block at `index` is the anchor. A reply anchor also
  /// matches the last text block of a line whose text blocks join to the
  /// reply, as `TranscriptTail.lastReply` joins them.
  private static func matches(_ line: TranscriptLine, _ index: Int, lastText: Int?, _ anchor: TranscriptAnchor) -> Bool
  {
    switch (anchor, line.blocks[index]) {
    case (.end, _): return true
    case (.toolCall(let tool, let input), .toolUse(_, let name, let used)): return name == tool && used == input
    case (.reply(let reply), .text(let text)):
      return text.trimmingCharacters(in: .whitespacesAndNewlines) == reply || (index == lastText && line.text == reply)
    default: return false
    }
  }

  private static func step(_ block: TranscriptLine.Block, at t: Int64?) -> TranscriptStep? {
    switch block {
    case .text(let text):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : TranscriptStep(kind: .text, text: trimmed, t: t)
    case .toolUse(let id, let name, let input):
      return TranscriptStep(kind: .tool, tool: name, summary: Attention.callLine(name, input), id: id, t: t)
    }
  }
}
