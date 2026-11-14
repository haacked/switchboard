import Foundation

/// A GitHub issue as `owner/name` and a number. `repo` is nil when the text
/// named only a number.
public struct IssueRef: Codable, Equatable, Hashable, Sendable {
  public var repo: String?
  public var number: Int

  public init(repo: String? = nil, number: Int) {
    self.repo = repo
    self.number = number
  }

  /// `init(parsing:)`, which throws an error that names the accepted forms.
  public static func parse(_ text: String) throws -> IssueRef {
    guard let ref = IssueRef(parsing: text) else {
      throw APIError("can't read \"\(text)\" as an issue. Use 123, #123, owner/name#123, or an issue URL.")
    }
    return ref
  }

  /// Reads `123`, `#123`, `owner/name#123`, or
  /// `https://github.com/owner/name/issues/123`, which may end in a further
  /// path, a query, or a fragment. A `/pull/` URL is not an issue.
  public init?(parsing text: String) {
    var number = text.trimmingCharacters(in: .whitespaces)
    var repo: String?
    if number.contains("://") {
      guard let url = URL(string: number), ["https", "http"].contains(url.scheme?.lowercased()),
        url.host?.lowercased() == "github.com"
      else { return nil }
      let parts = url.path.split(separator: "/").map(String.init)
      guard parts.count >= 4, parts[2] == "issues" else { return nil }
      repo = "\(parts[0])/\(parts[1])"
      number = parts[3]
    } else if let hash = number.firstIndex(of: "#") {
      let prefix = String(number[..<hash])
      if !prefix.isEmpty { repo = prefix }
      number = String(number[number.index(after: hash)...])
    }
    if let repo, !Issues.validRepo(repo) { return nil }
    guard let n = Issues.number(number) else { return nil }
    self.repo = repo
    self.number = n
  }
}

/// An issue that a session works on, as the summary shows it.
public struct SessionIssue: Codable, Equatable, Sendable {
  /// Where sbd found the issue.
  public enum Via: String, Codable, Sendable {
    /// `sb issue` set it.
    case set
    /// A closing keyword in the session's PR body names it.
    case body
    /// The branch name starts with its number.
    case branch

    public var title: String {
      switch self {
      case .set: "set with sb issue"
      case .body: "PR body"
      case .branch: "branch name"
      }
    }
  }

  /// owner/name, or nil when sbd does not know the repo.
  public var repo: String?
  public var number: Int
  public var via: Via
  /// The issue's page. nil when `repo` is nil.
  public var url: String?

  public init(repo: String?, number: Int, via: Via, url: String? = nil) {
    self.repo = repo
    self.number = number
    self.via = via
    self.url = url
  }

  /// The issue's page, or nil unless `url` is https. The app opens this link.
  public var link: URL? { url.flatMap(URL.init(httpsOnly:)) }

  /// `#N` for an issue in `repo` or in an unknown repo, and `owner/name#N`
  /// for an issue in another repo.
  public func label(from repo: String?) -> String {
    let same = self.repo.map { own in repo.map { Dependencies.sameRepo(own, $0) } ?? false } ?? true
    return Wait.PullRequest(repository: same ? nil : self.repo, number: number).text
  }
}

public enum Issues {
  /// GitHub's closing keywords as whole words, an optional colon, whitespace,
  /// and one ref. GitHub links only the ref right after a keyword.
  static let closingRef = try! NSRegularExpression(
    pattern:
      #"(?<![\w])(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?\s+(https?://github\.com/[\w.-]+/[\w.-]+/issues/[0-9]+(?:[/?#][^\s]*)?|(?:[\w.-]+/[\w.-]+)?#[0-9]+)(?![\w])"#,
    options: [.caseInsensitive])
  /// An HTML comment, or one that runs to the end of the body.
  static let htmlComment = try! NSRegularExpression(pattern: #"<!--[\s\S]*?(?:-->|\z)"#)

  /// The issues that the body's closing keywords name, in order and without
  /// repeats. `#N` names an issue in `repo`. Text in HTML comments and fenced
  /// code blocks does not count, because PR templates put examples there.
  /// nil when the body names none.
  public static func closingRefs(inBody body: String, repo: String) -> [IssueRef]? {
    guard closingRef.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil else { return nil }
    let text = withoutCode(
      htmlComment.stringByReplacingMatches(
        in: body, range: NSRange(body.startIndex..., in: body), withTemplate: " "))
    var refs: [IssueRef] = []
    var seen: Set<String> = []
    for match in closingRef.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let range = Range(match.range(at: 1), in: text), let found = IssueRef(parsing: String(text[range])) else {
        continue
      }
      let owner = found.repo ?? repo
      if seen.insert("\(owner.lowercased())#\(found.number)").inserted {
        refs.append(IssueRef(repo: owner, number: found.number))
      }
    }
    return refs.isEmpty ? nil : refs
  }

  /// The body without its fenced code blocks, by CommonMark's fence rules,
  /// which GitHub follows. A fence that never closes hides the rest of the
  /// body. A backtick fence's info string can't contain a backtick, so a line
  /// that starts with inline code opens no fence. Only a run of the same
  /// character, at least as long as the opening run and with nothing after
  /// it, closes a fence.
  static func withoutCode(_ body: String) -> String {
    var fence: (char: Character, count: Int)?
    var kept: [Substring] = []
    for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
      let trimmed = line.drop(while: { $0 == " " })
      let char = trimmed.first
      let run = trimmed.prefix { $0 == char }
      let rest = trimmed.dropFirst(run.count)
      let marker = (char == "`" || char == "~") && run.count >= 3
      if let open = fence {
        if marker, char == open.char, run.count >= open.count, rest.allSatisfy(\.isWhitespace) { fence = nil }
      } else if marker, let char, !(char == "`" && rest.contains("`")) {
        fence = (char, run.count)
      } else {
        kept.append(line)
      }
    }
    return kept.joined(separator: "\n")
  }

  /// The issue number at the start of the branch's last `/` part, as in
  /// `haacked/123-fix-cache`. The digits must be followed by `-` and a
  /// letter, which leaves out dates and versions. nil when the number is the
  /// session's own PR, because the branch then names the PR.
  public static func branchNumber(_ branch: String?, prNumber: Int?) -> Int? {
    guard let branch, let last = branch.split(separator: "/", omittingEmptySubsequences: false).last else {
      return nil
    }
    let digits = last.prefix { $0.isASCII && $0.isNumber }
    let rest = last.dropFirst(digits.count)
    guard rest.first == "-", let letter = rest.dropFirst().first, letter.isASCII, letter.isLetter,
      let n = number(String(digits)), n != prNumber
    else { return nil }
    return n
  }

  /// The issues that a work session shows. An issue set with `sb issue`
  /// replaces the others. Otherwise the PR body's closing refs show, or else
  /// the branch's number. nil when no source names one.
  public static func shown(set: IssueRef?, pr: PullRequest?, branch: String?) -> [SessionIssue]? {
    if let set { return [issue(repo: set.repo ?? pr?.repo, number: set.number, via: .set)] }
    if let refs = pr?.closesIssues, !refs.isEmpty {
      return refs.map { issue(repo: $0.repo, number: $0.number, via: .body) }
    }
    if let n = branchNumber(branch, prNumber: pr?.number) { return [issue(repo: pr?.repo, number: n, via: .branch)] }
    return nil
  }

  /// The url comes from a checked repo and a number, never from body text,
  /// because any local process can record a `pr` event.
  static func issue(repo: String?, number: Int, via: SessionIssue.Via) -> SessionIssue {
    guard let repo, validRepo(repo) else { return SessionIssue(repo: nil, number: number, via: via) }
    return SessionIssue(repo: repo, number: number, via: via, url: "https://github.com/\(repo)/issues/\(number)")
  }

  /// Whether `repo` is `owner/name` in the characters that GitHub allows.
  public static func validRepo(_ repo: String) -> Bool {
    let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 2
      && parts.allSatisfy { part in
        !part.isEmpty && part != "." && part != ".."
          && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }
      }
  }

  /// An issue number: 1 to 9 ASCII digits, and not 0.
  static func number(_ text: String) -> Int? {
    guard (1...9).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(text), n > 0
    else { return nil }
    return n
  }
}
