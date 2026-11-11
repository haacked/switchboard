import Foundation

/// Finds sessions by what the user types, for the app's search panel.
public enum SessionSearch {
  /// The fields that a query searches. The order breaks ties between fields.
  public enum Field: String, CaseIterable, Sendable {
    case name, branch, pr, issue, repo, prTitle, group, reason, note

    var weight: Int {
      switch self {
      case .name: 10
      case .branch, .pr, .issue: 9
      case .repo: 8
      case .prTitle, .group: 7
      case .reason: 5
      case .note: 4
      }
    }

    /// Whether a term may match the field's characters with gaps between them. Only short identifiers
    /// allow it, because in long text nearly every short term matches that way.
    var allowsSubsequence: Bool {
      switch self {
      case .name, .branch, .repo, .group: true
      case .pr, .issue, .prTitle, .reason, .note: false
      }
    }

    public var title: String {
      switch self {
      case .name: "Name"
      case .branch: "Branch"
      case .pr: "PR"
      case .issue: "Issue"
      case .repo: "Repo"
      case .prTitle: "PR"
      case .group: "Group"
      case .reason: "Reason"
      case .note: "Note"
      }
    }

    /// Whether a result row shows the field, so a match in it needs no hint.
    public var shownOnRow: Bool {
      switch self {
      case .name, .branch, .pr, .issue, .repo: true
      case .prTitle, .group, .reason, .note: false
      }
    }
  }

  public struct Hit: Equatable, Sendable {
    public var field: Field
    public var text: String

    public init(field: Field, text: String) {
      self.field = field
      self.text = text
    }
  }

  public struct Result: Equatable, Sendable, Identifiable {
    public var session: SessionSummary
    /// The session's repo label, for the row.
    public var repo: String?
    public var score: Int
    /// A match in a field that the row does not show, so the row can say why the session matched.
    public var hint: Hit?
    public var id: String { session.id }
  }

  /// The sessions that match every term of `query`, best match first, then the most recent activity. An
  /// empty query returns every session by recent activity.
  public static func rank(_ sessions: [SessionSummary], query: String) -> [Result] {
    let terms = fold(query).split(whereSeparator: \.isWhitespace).map { term -> String in
      let digits = term.dropFirst()
      return term.first == "#" && !digits.isEmpty && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
        ? String(digits) : String(term)
    }
    let labels = RepoLabels.labels(sessions, evenForOneRepo: true)
    var results: [(result: Result, name: String)] = []
    sessions: for s in sessions {
      let values = searchable(s, repo: labels[s.id])
      var score = 0
      var hint: Hit?
      for term in terms {
        guard let best = bestHit(term, in: values) else { continue sessions }
        score += best.score
        if hint == nil, !best.hit.field.shownOnRow { hint = best.hit }
      }
      // `searchable` puts the name first.
      results.append((Result(session: s, repo: labels[s.id], score: score, hint: hint), values[0].folded))
    }
    results.sort { a, b in
      if a.result.score != b.result.score { return a.result.score > b.result.score }
      if a.result.session.lastActivity != b.result.session.lastActivity {
        return a.result.session.lastActivity > b.result.session.lastActivity
      }
      if a.name != b.name { return a.name < b.name }
      return a.result.id < b.result.id
    }
    return results.map(\.result)
  }

  static let exact = 100
  static let prefix = 80
  static let wordPrefix = 60
  static let substring = 40
  static let subsequence = 20

  /// How well `term` matches `text`, both folded: exact, prefix, word prefix, substring, or subsequence
  /// when `subsequence` allows it. Nil when it does not match.
  static func tier(_ term: String, in text: String, subsequence allowsSubsequence: Bool) -> Int? {
    guard !term.isEmpty else { return nil }
    if text == term { return exact }
    if text.hasPrefix(term) { return prefix }
    // No range starts at the first character, because the prefix check above returned.
    let ranges = text.ranges(of: term)
    let startsAWord = ranges.contains { range in
      let before = text[text.index(before: range.lowerBound)]
      return !before.isLetter && !before.isNumber
    }
    if startsAWord { return wordPrefix }
    if !ranges.isEmpty { return substring }
    if allowsSubsequence && isSubsequence(term, of: text) { return subsequence }
    return nil
  }

  private static func isSubsequence(_ term: String, of text: String) -> Bool {
    var rest = term[...]
    for c in text where c == rest.first {
      rest = rest.dropFirst()
      if rest.isEmpty { return true }
    }
    return false
  }

  private static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }

  private struct Value {
    var field: Field
    var text: String
    var folded: String
  }

  /// The session's searchable values in `Field` order.
  private static func searchable(_ s: SessionSummary, repo: String?) -> [Value] {
    var values: [(Field, String)] = [(.name, s.name)]
    if let branch = s.branch { values.append((.branch, branch)) }
    if let pr = s.pr { values.append((.pr, String(pr.number))) }
    for issue in s.issues ?? [] { values.append((.issue, String(issue.number))) }
    if let repo { values.append((.repo, repo)) }
    if let pr = s.pr {
      values.append((.repo, pr.repo))
      values.append((.prTitle, pr.title))
    }
    if let group = s.groupName { values.append((.group, group)) }
    values.append((.reason, s.reason))
    for note in s.notes { values.append((.note, note.text)) }
    return values.map { Value(field: $0.0, text: $0.1, folded: fold($0.1)) }
  }

  /// The highest-scoring value for `term`. A tie goes to the earlier value.
  private static func bestHit(_ term: String, in values: [Value]) -> (hit: Hit, score: Int)? {
    var best: (hit: Hit, score: Int)?
    for v in values {
      guard let t = tier(term, in: v.folded, subsequence: v.field.allowsSubsequence) else { continue }
      let score = t * v.field.weight
      if score > best?.score ?? 0 { best = (Hit(field: v.field, text: v.text), score) }
    }
    return best
  }
}
