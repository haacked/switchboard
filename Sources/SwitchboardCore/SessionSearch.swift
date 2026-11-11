import Foundation

/// Finds sessions by what the user types, for the app's search panel.
public enum SessionSearch {
  /// The fields that a query searches.
  public enum Field: Sendable {
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

    /// Whether a result row shows the field, so a match in it needs no hint. `searchable` overrides it for a value
    /// that the row leaves out.
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
    let labels = RepoLabels.fullLabels(sessions, evenForOneRepo: true)
    var results: [(result: Result, name: String)] = []
    sessions: for s in sessions {
      let values = searchable(s, repo: labels[s.id])
      var score = 0
      var hint: Hit?
      for term in terms {
        guard let best = bestHit(term, in: values) else { continue sessions }
        score += best.score
        if hint == nil, !best.value.shown { hint = Hit(field: best.value.field, text: best.value.text) }
      }
      // `searchable` puts the name first.
      let result = Result(session: s, repo: labels[s.id].map(RepoLabels.capped), score: score, hint: hint)
      results.append((result, values[0].folded))
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
    /// Whether the result row shows this value, so a match in it needs no hint.
    var shown: Bool
  }

  /// The session's searchable values. `bestHit` keeps the earlier of two values with the same score, so this
  /// order breaks ties between fields. `repo` is the full label, before `RepoLabels.capped` shortens it for the row.
  private static func searchable(_ s: SessionSummary, repo: String?) -> [Value] {
    var values: [Value] = []
    func add(_ field: Field, _ text: String, shown: Bool? = nil) {
      values.append(Value(field: field, text: text, folded: fold(text), shown: shown ?? field.shownOnRow))
    }
    add(.name, s.name)
    if let branch = s.branch { add(.branch, branch) }
    if let pr = s.pr { add(.pr, String(pr.number)) }
    // The row's issue badge names only the first issue.
    for (i, issue) in (s.issues ?? []).enumerated() { add(.issue, String(issue.number), shown: i == 0) }
    if let repo { add(.repo, repo, shown: RepoLabels.capped(repo) == repo) }
    if let pr = s.pr {
      // The row shows the folder's label, not the PR's owner/name.
      if pr.repo != repo { add(.repo, pr.repo, shown: false) }
      add(.prTitle, pr.title)
    }
    if let group = s.groupName { add(.group, group) }
    add(.reason, s.reason)
    for note in s.notes { add(.note, note.text) }
    return values
  }

  /// The highest-scoring value for `term`. A tie goes to the earlier value.
  private static func bestHit(_ term: String, in values: [Value]) -> (value: Value, score: Int)? {
    var best: (value: Value, score: Int)?
    for v in values {
      guard let t = tier(term, in: v.folded, subsequence: v.field.allowsSubsequence) else { continue }
      let score = t * v.field.weight
      if score > best?.score ?? 0 { best = (v, score) }
    }
    return best
  }
}
