import Foundation

/// The title and buttons of an offer that no summary describes, built from
/// the reply's own words.
public enum OfferText {
  static let pronouns: Set = ["it", "this", "that"]
  /// The nouns that name what a candidate is, such as "the branch x".
  static let nouns: Set = ["branch", "file", "folder", "directory", "worktree", "tag", "commit", "pr"]
  static let tokenTrim = CharacterSet(charactersIn: ".,;:!?()[]\"'`*_")

  /// The offer as a question that starts with its verb, such as "Delete the
  /// branch x?" for "Do you want me to delete it?". The pronoun after the
  /// verb names an object only when `previous`, the sentence before the
  /// question, names exactly one. Otherwise the pronoun stays.
  public static func title(question: String, previous: String?) -> String {
    let limit = Triage.titleLength
    let text = plain(question)
    guard let prefix = Attention.offerPrefix(text) else { return Triage.title(text) }
    let phrase = Triage.capitalized(text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
    var words = phrase.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard words.count >= 2, let referents = previous.flatMap(referents) else { return Triage.title(phrase) }
    let word = words[1]
    let bare = word.trimmingCharacters(in: tokenTrim)
    guard pronouns.contains(bare.lowercased()), let range = word.range(of: bare) else { return Triage.title(phrase) }
    for referent in referents {
      words[1] = word.replacingCharacters(in: range, with: referent)
      let named = words.joined(separator: " ")
      if named.count <= limit { return named }
    }
    return Triage.title(phrase)
  }

  /// Whether the offer can take a plain Yes or No: a question that names no
  /// alternative with "or".
  public static func isYesNo(_ question: String) -> Bool {
    question.hasSuffix("?") && !GroupSuggestions.words(question).contains("or")
  }

  /// The names that a pronoun can stand for, longest first: "the <noun>
  /// <name>" when a noun stands next to the name, and the name alone. nil
  /// when the sentence names no object, or more than one.
  static func referents(_ sentence: String) -> [String]? {
    let text = paragraph(sentence)
    let spans = Set((text?.runs ?? []).filter { $0.style.contains(.code) }.map(\.text))
    let tokens = (text?.plain ?? sentence).split(whereSeparator: \.isWhitespace).map {
      $0.trimmingCharacters(in: tokenTrim)
    }
    let candidates = spans.isEmpty ? Set(tokens.filter(isPathLike)) : spans
    guard candidates.count == 1, let name = candidates.first else { return nil }
    guard let at = tokens.firstIndex(of: name) else { return [name] }
    let neighbors = [at > 0 ? tokens[at - 1] : nil, at + 1 < tokens.count ? tokens[at + 1] : nil]
    guard let noun = neighbors.compactMap({ $0 }).first(where: { nouns.contains($0.lowercased()) }) else {
      return [name]
    }
    return ["the \(noun) \(name)", name]
  }

  /// A word such as owner/branch or docs/notes.md: a "/" with a letter or
  /// digit on each side, and no "://".
  static func isPathLike(_ token: String) -> Bool {
    guard !token.contains("://") else { return false }
    let chars = Array(token)
    return chars.indices.contains { i in
      chars[i] == "/" && i > 0 && i + 1 < chars.count && isWordCharacter(chars[i - 1]) && isWordCharacter(chars[i + 1])
    }
  }

  static func plain(_ markdown: String) -> String { paragraph(markdown)?.plain ?? markdown }

  /// The text when the Markdown is one paragraph.
  static func paragraph(_ markdown: String) -> MarkdownText? {
    let blocks = MarkdownBlock.parse(markdown)
    guard case .paragraph(let text)? = blocks.first, blocks.count == 1 else { return nil }
    return text
  }

  static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
}
