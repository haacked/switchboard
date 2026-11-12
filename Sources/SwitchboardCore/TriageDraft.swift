import Foundation

/// A message that the session wrote for the user to send to someone else,
/// such as a review request. The Inbox shows its text as written and copies
/// it as Markdown source. `replyTo` is the `html_url` of the GitHub comment
/// that the message answers, as the session's card wrote it.
public struct TriageDraft: Codable, Equatable, Sendable {
  public var label: String?
  public var text: String
  public var replyTo: String?

  public init(label: String? = nil, text: String, replyTo: String? = nil) {
    self.label = label
    self.text = text
    self.replyTo = replyTo
  }
}

/// A draft as an Inbox item shows it. `number` is the draft's 1-based
/// position in the card, so the item's ref and the number name one draft.
public struct InboxDraft: Codable, Equatable, Sendable {
  public var number: Int
  public var label: String?
  public var text: String
  public var replyTo: String?
  public var post: DraftPost

  public init(_ draft: TriageDraft, number: Int, post: DraftPost = .copyOnly(reason: nil)) {
    self.number = number
    label = draft.label
    text = draft.text
    replyTo = draft.replyTo
    self.post = post
  }

  private enum CodingKeys: String, CodingKey { case number, label, text, replyTo, post }

  /// An item that an older sbd wrote has drafts without a number, a target, or a state.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 0
    label = try c.decodeIfPresent(String.self, forKey: .label)
    text = try c.decode(String.self, forKey: .text)
    replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)
    post = try c.decodeIfPresent(DraftPost.self, forKey: .post) ?? .copyOnly(reason: nil)
  }
}

public enum TriageDrafts {
  public static let maxDrafts = 5
  /// sbd drops a longer draft rather than cut it, because the user would
  /// paste a cut draft as if it were whole.
  public static let maxLength = 10_000
  public static let replyToLength = 500

  /// The drafts that a card names, as strings or as `{label, text, replyTo}` objects.
  /// Each element that fails or doesn't fit adds a line to `dropped`.
  static func read(_ list: JSON?, _ dropped: inout [String]) -> [TriageDraft] {
    var index = 0
    var targets: [String] = []
    let drafts = TriageCard.keep(list, "draft", max: maxDrafts, &dropped) { raw in
      defer { index += 1 }
      return try draft(raw, index: index, &targets)
    }
    dropped += targets
    return drafts
  }

  /// One element of a card's drafts, as a string or a `{label, text, replyTo}`
  /// object. A `replyTo` that isn't a string of at most `replyToLength`
  /// characters adds a line to `dropped`, and the draft stays without it.
  static func draft(_ raw: JSON, index: Int, _ dropped: inout [String]) throws -> TriageDraft {
    let text = raw.string ?? raw["text"]?.string ?? ""
    let label = oneLine(raw["label"]?.string ?? "", max: TriageCard.labelLength)
    var draft = try checked(TriageDraft(label: label.isEmpty ? nil : label, text: trimBlankLines(text)))
    switch raw["replyTo"] {
    case nil, .null?:
      break
    case .string(let url)?:
      let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
      if url.count > replyToLength {
        dropped.append(
          TriageCard.droppedLine(
            "replyTo of draft", label: draft.label, index: index,
            APIError("it has \(url.count) characters, and a replyTo has at most \(replyToLength)")))
      } else if !url.isEmpty {
        draft.replyTo = url
      }
    default:
      dropped.append(
        TriageCard.droppedLine("replyTo of draft", label: draft.label, index: index, APIError("it is not text")))
    }
    return draft
  }

  /// The drafts whose text appears in the reply, each with the reply's own
  /// text. The model copies the text. This drops a copy that differs from
  /// the reply in any character, so the Inbox never shows a paraphrase as
  /// the session's draft. A draft that the reply quotes matches without its
  /// quote markers. A draft that the reply doesn't quote keeps any `>`
  /// lines of its own. The copy must start and end on line breaks of the
  /// reply. This drops a copy that the model cut in the middle of a line.
  public static func verbatim(_ drafts: [TriageDraft], in reply: String) -> (kept: [TriageDraft], dropped: [String]) {
    let plain = lines(normalize(reply, unquote: false))
    let unquoted = lines(normalize(reply, unquote: true))
    var kept: [TriageDraft] = []
    var dropped: [String] = []
    for (i, draft) in drafts.enumerated() {
      do {
        let asIs = trimBlankLines(normalize(draft.text, unquote: false))
        let bare = trimBlankLines(normalize(draft.text, unquote: true))
        let text: String
        if !quoted(asIs), plain.contains(lines(asIs)) {
          text = asIs
        } else if unquoted.contains(lines(bare)) {
          text = bare
        } else {
          throw APIError("its text is not in the reply")
        }
        kept.append(try checked(TriageDraft(label: draft.label, text: text, replyTo: nil)))
      } catch {
        dropped.append(TriageCard.droppedLine("draft", label: draft.label, index: i, error))
      }
    }
    return (kept, dropped)
  }

  /// The text between line breaks, so that `contains` matches only whole lines.
  private static func lines(_ text: String) -> String { "\n" + text + "\n" }

  private static func checked(_ draft: TriageDraft) throws -> TriageDraft {
    guard !draft.text.isEmpty else { throw APIError("it has no text") }
    guard draft.text.count <= maxLength else {
      throw APIError("it has \(draft.text.count) characters, and a draft has at most \(maxLength)")
    }
    return draft
  }

  /// The text with LF line ends and no trailing whitespace on any line.
  /// `unquote` also removes one blockquote marker from each line.
  static func normalize(_ text: String, unquote: Bool) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
      .map { line -> String in
        var rest = Substring(line)
        if unquote, let marker = quoteMarker(rest) { rest = rest.dropFirst(marker) }
        while let last = rest.last, last.isWhitespace { rest = rest.dropLast() }
        return String(rest)
      }
      .joined(separator: "\n")
  }

  /// Whether every line that has text starts with a blockquote marker, as a
  /// copy of a quoted draft that keeps its markers does.
  private static func quoted(_ text: String) -> Bool {
    let lines = text.split(separator: "\n")
    return !lines.isEmpty && lines.allSatisfy { quoteMarker($0) != nil }
  }

  /// The length of the line's blockquote marker: up to 3 spaces, `>`, and one optional space.
  private static func quoteMarker(_ line: Substring) -> Int? {
    let indent = line.prefix { $0 == " " }.count
    guard indent <= 3, line.dropFirst(indent).first == ">" else { return nil }
    return indent + 1 + (line.dropFirst(indent + 1).first == " " ? 1 : 0)
  }

  static func trimBlankLines(_ text: String) -> String {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    while let first = lines.first, first.allSatisfy(\.isWhitespace) { lines.removeFirst() }
    while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
    return lines.joined(separator: "\n")
  }
}
