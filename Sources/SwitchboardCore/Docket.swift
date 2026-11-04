import Foundation

/// How sbd runs `docket mcp`.
public struct DocketSettings: Codable, Equatable, Sendable {
  /// The docket CLI. sbd looks a name without a slash up on PATH and in the
  /// usual bin folders, then in GOBIN and ~/go/bin, where `go install` puts it.
  public var path: String = "docket"
  /// How often sbd asks docket about the open reviews, on sbd's clock. 0 turns the poll off.
  public var pollSeconds: Double = 30
  /// How long one `docket mcp` run may take. `list_reviews` asks claude and GitHub first.
  public var timeoutSeconds: Double = 120

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = DocketSettings()
    path = try c.decodeIfPresent(String.self, forKey: .path) ?? d.path
    pollSeconds = try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? d.pollSeconds
    timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
  }

  /// The docket that `path` names. launchd's PATH has neither GOBIN nor ~/go/bin.
  public func executable(home: String = NSHomeDirectory(), environment: [String: String]) -> String? {
    if let found = findExecutable(path) { return found }
    guard !path.contains("/") else { return nil }
    return [environment["GOBIN"], "\(home)/go/bin"].compactMap { $0 }.map { "\($0)/\(path)" }
      .first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}

/// The review that a docket row tracks. docket names a pull request as `org/repo#N`.
public struct DocketSession: Codable, Equatable, Sendable {
  public var pullRequest: String
  public var url: String

  public init(pullRequest: String, url: String) {
    self.pullRequest = pullRequest
    self.url = url
  }
}

/// A review as docket's `list_reviews` and `start_review` report it. docket
/// sends snake_case keys, which `DocketClient` converts.
public struct DocketReview: Codable, Equatable, Sendable {
  public var pullRequest: String
  public var url: String
  public var title: String?
  public var author: String?
  /// docket's state: preparing, reviewing, drafted, submitted, unreviewed, reviewed, or not_started.
  public var state: String
  /// OPEN, MERGED, or CLOSED, when docket last read GitHub.
  public var prState: String?
  public var notesPath: String?
  public var error: String?
  public var progress: DocketProgress?

  public init(pullRequest: String, url: String, state: String) {
    self.pullRequest = pullRequest
    self.url = url
    self.state = state
  }
}

/// What a running background review is doing. It leaves out docket's
/// `updated_at` and agent count. A poll that changes only those fields records no event.
public struct DocketProgress: Codable, Equatable, Sendable {
  public var detail: String?
  /// True while the review's claude session waits on the user.
  public var waiting: Bool?
  public var needs: String?

  public init(detail: String? = nil, waiting: Bool? = nil, needs: String? = nil) {
    self.detail = detail
    self.waiting = waiting
    self.needs = needs
  }
}

/// What a docket row's `docket` events say.
public struct DocketStatus: Codable, Equatable, Sendable {
  /// The review as the last good poll, or the start, read it.
  public var review: DocketReview?
  /// True once `list_reviews` no longer lists the review, which docket does
  /// after it archives or abandons it.
  public var closed = false
  /// Why the last poll couldn't read docket, until a poll succeeds.
  public var problem: String?

  public init() {}

  /// A `docket` event holds `review`, `closed`, or `problem`.
  public mutating func apply(_ data: JSON) {
    if let review = data["review"], let r = try? JSONCoding.convert(review, to: DocketReview.self) {
      self.review = r
      closed = false
      problem = nil
    } else if data["closed"]?.bool == true {
      closed = true
      problem = nil
    } else if let problem = data["problem"]?.string {
      self.problem = problem
    }
  }
}

/// What `sb ls` and `sb get` show for a docket row.
public struct DocketSummary: Codable, Equatable, Sendable {
  public var pullRequest: String
  public var url: String
  public var review: DocketReview?
  public var closed: Bool
  public var problem: String?

  public init(_ session: DocketSession, _ status: DocketStatus) {
    pullRequest = session.pullRequest
    url = session.url
    review = status.review
    closed = status.closed
    problem = status.problem
  }
}

/// A pull request as docket names it. It reads what docket's `ParseRef`
/// reads, and it compares the way docket's `Ref.Equal` does.
public struct DocketRef: Sendable {
  public var org: String
  public var repo: String
  public var number: Int

  /// Reads a PR URL with or without its scheme and `www.`, `org/repo#N`,
  /// `org/repo/pull/N`, or `N` and `#N` against `defaultRepo`. It returns nil
  /// for a bare number without a `defaultRepo` and for anything docket refuses.
  public init?(_ input: String, defaultRepo: String? = nil) {
    let s = input.trimmingCharacters(in: .whitespaces)
    if let m = DocketRef.named.lazy.compactMap({ DocketRef.groups($0, s) }).first {
      self.init(org: m[0], repo: m[1], number: m[2])
      return
    }
    guard let m = DocketRef.groups(DocketRef.plain, s), let slug = defaultRepo else { return nil }
    let parts = slug.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2 else { return nil }
    self.init(org: parts[0], repo: parts[1], number: m[0])
  }

  private init?(org: String, repo: String, number: String) {
    let repo = repo.hasSuffix(".git") ? String(repo.dropLast(4)) : repo
    guard let n = Int(number), n > 0, DocketRef.groups(DocketRef.segment, org) != nil,
      DocketRef.groups(DocketRef.segment, repo) != nil
    else { return nil }
    self.org = org
    self.repo = repo
    self.number = n
  }

  /// `org/repo#N`, the form docket reports.
  public var text: String { "\(org)/\(repo)#\(number)" }

  /// GitHub ignores the case of an owner and a repository name, so docket does too.
  public func matches(_ other: DocketRef) -> Bool {
    number == other.number && org.caseInsensitiveCompare(other.org) == .orderedSame
      && repo.caseInsensitiveCompare(other.repo) == .orderedSame
  }

  /// True when `pullRequest`, in a form docket reads without a default repo, names this PR.
  public func names(_ pullRequest: String) -> Bool {
    DocketRef(pullRequest).map(matches) ?? false
  }

  /// The top-level `default_repo` in docket's `config.toml` under `docketHome`.
  public static func defaultRepo(docketHome: String) -> String? {
    guard let text = try? String(contentsOfFile: "\(docketHome)/config.toml", encoding: .utf8) else { return nil }
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") { return nil }
      guard let eq = line.firstIndex(of: "="), line[..<eq].trimmingCharacters(in: .whitespaces) == "default_repo"
      else { continue }
      let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      guard let quote = value.first, quote == "\"" || quote == "'",
        let end = value.dropFirst().firstIndex(of: quote)
      else { return nil }
      return String(value[value.index(after: value.startIndex)..<end])
    }
    return nil
  }

  private static let named = [
    #"^(?:https?://)?(?:www\.)?github\.com/([^/]+)/([^/]+)/pull/(\d+)"#,
    #"^([^/\s]+)/([^/#\s]+)#(\d+)$"#,
    #"^([^/\s]+)/([^/\s]+)/pull/(\d+)$"#,
  ].map { try! NSRegularExpression(pattern: $0) }
  private static let plain = try! NSRegularExpression(pattern: #"^#?(\d+)$"#)
  private static let segment = try! NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#)

  private static func groups(_ regex: NSRegularExpression, _ s: String) -> [String]? {
    guard let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
  }
}

extension Attention {
  /// The state of a docket row, or nil for any other session.
  static func docketVerdict(_ session: Session, _ facts: SessionFacts) -> Verdict? {
    guard session.docket != nil else { return nil }
    let status = facts.docket
    if let problem = status.problem {
      return Verdict(state: .needsYou, reason: oneLine("can't read docket: \(problem)"))
    }
    if status.closed { return Verdict(state: .done, reason: "docket closed the review") }
    guard let r = status.review else { return Verdict(state: .working, reason: "starting the review") }
    let error = r.error.flatMap { $0.isEmpty ? nil : $0 }
    switch r.state {
    case "not_started":
      return Verdict(state: .needsYou, reason: oneLine("did not start: \(error ?? "docket gave no reason")"))
    case "preparing":
      if let error { return Verdict(state: .needsYou, reason: oneLine("docket: \(error)")) }
      return Verdict(state: .working, reason: "preparing the review")
    case "reviewing":
      if r.progress?.waiting == true {
        let needs = r.progress?.needs.flatMap { $0.isEmpty ? nil : $0 } ?? "answer it in docket"
        return Verdict(state: .needsYou, reason: oneLine("review needs you: \(needs)"))
      }
      guard let detail = r.progress?.detail, !detail.isEmpty else {
        return Verdict(state: .working, reason: "reviewing")
      }
      return Verdict(state: .working, reason: oneLine("reviewing: \(detail)"))
    case "drafted":
      let pr = r.prState.flatMap { $0 == "OPEN" ? nil : " (PR \($0.lowercased()))" } ?? ""
      return Verdict(state: .needsYou, reason: "draft ready to submit\(pr)")
    case "unreviewed":
      return Verdict(state: .needsYou, reason: "the review ended without a draft")
    case "submitted":
      return Verdict(state: .done, reason: "review submitted")
    case "reviewed":
      return Verdict(state: .done, reason: "reviewed")
    default:
      return Verdict(state: .needsYou, reason: oneLine("docket reports \(r.state)"))
    }
  }
}
