import Foundation

/// The GitHub comment, review, or PR conversation comment that a draft
/// replies to, as its `replyTo` URL names it.
public struct ReplyTarget: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case reviewComment, issueComment, review
  }

  /// `owner/name`, in the URL's case.
  public var repo: String
  public var pr: Int
  public var kind: Kind
  public var id: Int64

  public init(repo: String, pr: Int, kind: Kind, id: Int64) {
    self.repo = repo
    self.pr = pr
    self.kind = kind
    self.id = id
  }

  private static let fragments: [(prefix: String, kind: Kind)] = [
    ("discussion_r", .reviewComment), ("r", .reviewComment), ("issuecomment-", .issueComment),
    ("pullrequestreview-", .review),
  ]
  private static let name = try! NSRegularExpression(pattern: #"\A[A-Za-z0-9_.-]+\z"#)
  private static let positive = try! NSRegularExpression(pattern: #"\A[1-9][0-9]*\z"#)

  /// The target that a comment's `html_url` names. sbd never guesses: any
  /// other host, scheme, path, query, or fragment throws, and the error is
  /// the reason that the draft is copy-only.
  public static func parse(_ url: String) throws -> ReplyTarget {
    guard let c = URLComponents(string: url), c.scheme == "https", c.host == "github.com", c.user == nil,
      c.password == nil, c.port == nil
    else { throw APIError("replyTo is not an https://github.com URL") }
    guard c.query == nil else { throw APIError("replyTo has a query string") }
    var parts = c.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    if parts.count == 6, ["files", "changes"].contains(parts[5]) { parts.removeLast() }
    guard parts.count == 5, parts[0].isEmpty, parts[3] == "pull", fullMatch(name, parts[1]),
      fullMatch(name, parts[2]), ![parts[1], parts[2]].contains(where: { $0 == "." || $0 == ".." }),
      fullMatch(positive, parts[4]), let pr = Int(parts[4])
    else { throw APIError("replyTo doesn't name a pull request on github.com") }
    guard let fragment = c.percentEncodedFragment, !fragment.isEmpty else {
      throw APIError("replyTo has no #discussion_r, #issuecomment-, or #pullrequestreview- fragment")
    }
    for (prefix, kind) in fragments where fragment.hasPrefix(prefix) {
      let digits = String(fragment.dropFirst(prefix.count))
      if fullMatch(positive, digits), let id = Int64(digits) {
        return ReplyTarget(repo: "\(parts[1])/\(parts[2])", pr: pr, kind: kind, id: id)
      }
    }
    throw APIError("replyTo's fragment \"\(oneLine(fragment, max: 40))\" doesn't name a comment")
  }

  private static func fullMatch(_ regex: NSRegularExpression, _ text: String) -> Bool {
    regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  /// Whether the target is on `pr`. GitHub ignores the repo's case.
  public func matches(_ pr: PullRequest) -> Bool {
    Dependencies.sameRepo(repo, pr.repo) && self.pr == pr.number
  }

  /// The `gh api` path that reads the comment.
  public var getPath: String {
    switch kind {
    case .reviewComment: "repos/\(repo)/pulls/comments/\(id)"
    case .issueComment: "repos/\(repo)/issues/comments/\(id)"
    case .review: "repos/\(repo)/pulls/\(pr)/reviews/\(id)"
    }
  }

  /// Checks that GitHub places `comment`, as `getPath` reads it, on the
  /// target's PR. A review comment that replies to another gives no
  /// resolution yet: its parent is the root to fetch next.
  public static func resolution(of target: ReplyTarget, comment: JSON) throws -> (
    resolved: ResolvedTarget?, rootToFetch: Int64?
  ) {
    try target.requireOnPR(comment, id: target.id)
    if target.kind == .reviewComment, let parent = parentId(comment) { return (nil, parent) }
    return (try ResolvedTarget(target: target, root: target.id, comment: comment), nil)
  }

  /// The resolution of a review comment that replies to `rootComment`. The
  /// reply goes to the thread's root, so the root must be on the target's PR
  /// and reply to nothing.
  public static func root(of target: ReplyTarget, rootComment: JSON, child: JSON) throws -> ResolvedTarget {
    guard let root = parentId(child) else { throw APIError("GitHub reports no thread root for comment \(target.id)") }
    try target.requireOnPR(rootComment, id: root)
    guard parentId(rootComment) == nil else {
      throw APIError("GitHub reports a reply chain deeper than one, so sbd can't find the thread's root")
    }
    return try ResolvedTarget(target: target, root: root, comment: child)
  }

  /// A review comment's `in_reply_to_id`. A missing or null one means none.
  private static func parentId(_ comment: JSON) -> Int64? {
    comment["in_reply_to_id"]?.int.map(Int64.init)
  }

  /// Requires that the comment's `pull_request_url`, or an issue comment's
  /// `issue_url`, ends in this target's repo and PR number.
  private func requireOnPR(_ comment: JSON, id: Int64) throws {
    let (key, segment) = kind == .issueComment ? ("issue_url", "issues") : ("pull_request_url", "pulls")
    let url = comment[key]?.string ?? ""
    guard url.lowercased().hasSuffix("/repos/\(repo)/\(segment)/\(pr)".lowercased()) else {
      throw APIError(
        url.isEmpty
          ? "GitHub doesn't say which PR comment \(id) is on"
          : "GitHub places comment \(id) on another PR than \(repo)#\(pr): \(url)")
    }
  }
}

/// A target that gh read and that GitHub places on the session's PR. Its
/// JSON is flat: the target's fields sit beside the resolution's.
public struct ResolvedTarget: Codable, Equatable, Sendable {
  public static let excerptLength = 200

  public var target: ReplyTarget
  /// The comment that a post replies to: the thread's root for a review
  /// comment, and the target's own id for the other kinds.
  public var root: Int64
  public var author: String
  public var path: String?
  public var line: Int?
  public var excerpt: String
  public var url: String

  public init(
    target: ReplyTarget, root: Int64, author: String, path: String?, line: Int?, excerpt: String, url: String
  ) {
    self.target = target
    self.root = root
    self.author = author
    self.path = path
    self.line = line
    self.excerpt = excerpt
    self.url = url
  }

  /// The comment's author, place, and text, as GitHub answered for it.
  init(target: ReplyTarget, root: Int64, comment: JSON) throws {
    guard let author = comment["user"]?["login"]?.string else {
      throw APIError("GitHub's answer for comment \(target.id) has no author")
    }
    guard let url = comment["html_url"]?.string else {
      throw APIError("GitHub's answer for comment \(target.id) has no URL")
    }
    self.init(
      target: target, root: root, author: author, path: comment["path"]?.string,
      line: comment["line"]?.int ?? comment["original_line"]?.int,
      excerpt: oneLine(comment["body"]?.string ?? "", max: Self.excerptLength), url: url)
  }

  /// Whether a reply to `other` goes where a reply to this target goes. Two
  /// replies in one review thread share their root.
  public func sameThread(as other: ResolvedTarget) -> Bool {
    Dependencies.sameRepo(target.repo, other.target.repo) && target.pr == other.target.pr
      && target.kind == other.target.kind && root == other.root
  }

  /// The `gh api` arguments that post `body` as a reply. A review comment's
  /// reply goes to its thread. A reply to an issue comment or a review is a
  /// new PR conversation comment. `-f` sends the body as it is, where `-F`
  /// would read `@path` as a file and convert true, false, null, and numbers.
  public func postArgs(body: String) -> [String] {
    let path =
      switch target.kind {
      case .reviewComment: "repos/\(target.repo)/pulls/\(target.pr)/comments/\(root)/replies"
      case .issueComment, .review: "repos/\(target.repo)/issues/\(target.pr)/comments"
      }
    return ["api", "-X", "POST", path, "-f", "body=\(body)"]
  }

  private enum CodingKeys: String, CodingKey { case kind, repo, pr, id, root, author, path, line, excerpt, url }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    target = ReplyTarget(
      repo: try c.decode(String.self, forKey: .repo), pr: try c.decode(Int.self, forKey: .pr),
      kind: try c.decode(ReplyTarget.Kind.self, forKey: .kind), id: try c.decode(Int64.self, forKey: .id))
    root = try c.decode(Int64.self, forKey: .root)
    author = try c.decode(String.self, forKey: .author)
    path = try c.decodeIfPresent(String.self, forKey: .path)
    line = try c.decodeIfPresent(Int.self, forKey: .line)
    excerpt = try c.decode(String.self, forKey: .excerpt)
    url = try c.decode(String.self, forKey: .url)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(target.kind, forKey: .kind)
    try c.encode(target.repo, forKey: .repo)
    try c.encode(target.pr, forKey: .pr)
    try c.encode(target.id, forKey: .id)
    try c.encode(root, forKey: .root)
    try c.encode(author, forKey: .author)
    try c.encodeIfPresent(path, forKey: .path)
    try c.encodeIfPresent(line, forKey: .line)
    try c.encode(excerpt, forKey: .excerpt)
    try c.encode(url, forKey: .url)
  }
}
