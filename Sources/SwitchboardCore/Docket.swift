import Foundation

/// How sbd runs `docket mcp`.
public struct DocketSettings: Codable, Equatable, Sendable {
  /// The docket CLI. sbd looks a name without a slash up on PATH and in the usual bin folders.
  public var path: String = "docket"
  /// How often sbd asks docket about the open reviews, on sbd's clock.
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

public enum DocketRef {
  /// Returns `o/r#N`, the form docket reports, for a PR URL or for `o/r#N`.
  /// Anything else, such as a bare number that docket reads against its
  /// `default_repo`, comes back unchanged.
  public static func normalize(_ input: String) -> String {
    Wait.PullRequest(parsing: input).flatMap { $0.repository == nil ? nil : $0.text } ?? input
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
