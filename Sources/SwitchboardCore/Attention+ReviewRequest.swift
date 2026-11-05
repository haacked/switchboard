import Foundation

/// A review request that sbd ran or the user dismissed, as a `review-request`
/// event recorded it.
public struct ReviewRequestAttempt: Codable, Equatable, Sendable {
  public enum Result: String, Codable, Sendable {
    case requested
    case failed
    case dismissed
  }

  public static let event = "review-request"

  /// The PR's head commit when the attempt ran.
  public var head: String
  public var result: Result
  /// The logins and teams that the request named.
  public var reviewers: [String]?
  /// gh's error when the request failed.
  public var error: String?

  public init(head: String, result: Result, reviewers: [String]? = nil, error: String? = nil) {
    self.head = head
    self.result = result
    self.reviewers = reviewers
    self.error = error
  }
}

extension SessionFacts {
  /// The last review request at the PR's current head commit. A push makes
  /// earlier attempts irrelevant.
  public var currentReviewRequest: ReviewRequestAttempt? {
    guard let reviewRequest, reviewRequest.head == pr?.headSha else { return nil }
    return reviewRequest
  }

  /// gh's error from a failed review request at the PR's current head commit.
  public var reviewRequestError: String? {
    guard let attempt = currentReviewRequest, attempt.result == .failed else { return nil }
    return attempt.error
  }
}

extension Attention {
  /// The review card for an idle session whose open PR is not a draft, has
  /// no review other than a pending one, has no reviewer that GitHub asks
  /// for, is not approved, has no failed checks, has no conflict or merged
  /// base, is not in Trunk's queue, and is not held by a dependency, and
  /// whose last reply asks nothing and offers nothing. A request at the
  /// current head commit moves the session to Ready for review with the
  /// reviewers it named, and a dismissal at that commit leaves the reply's
  /// verdict. `rules` calls it after the rules for running subagents and
  /// jobs.
  static func unreviewedPR(_ facts: SessionFacts) -> Verdict? {
    guard let pr = facts.pr, pr.ready, pr.reviewRequests == [], !pr.reviews.contains(where: { $0.state != "PENDING" }),
      !pr.isApproved, !pr.checksFailed, pr.mergeable != .conflicting, pr.mergedBase == nil, pr.queue == nil,
      !facts.dependencies.contains(where: \.holds), classify(facts.lastReply ?? "") == .other
    else { return nil }
    let attempt = facts.currentReviewRequest
    switch attempt?.result {
    case .dismissed:
      return nil
    case .requested:
      var asked = facts
      asked.pr?.reviewRequests = attempt?.reviewers ?? []
      return readyPRLine(asked).map { Verdict(state: .readyForReview, reason: oneLine($0, max: 200)) }
    case .failed, nil:
      let checks = pr.checks.map { "Checks \($0.lowercased())" } ?? "No checks"
      return Verdict(
        state: .needsYou, reason: "#\(pr.number) is ready for review",
        options: [
          TriageOption(label: "Request review", action: .requestReview, recommended: true),
          TriageOption(label: "Dismiss", action: .dismissReview),
        ],
        callouts: facts.reviewRequestError.map { [Callout(kind: .warning, title: "The last review request failed", body: $0)] }
          ?? [],
        summary: "\(oneLine("#\(pr.number) \(pr.title)", max: 200))\n\(checks). Nobody has reviewed it, and GitHub asks nobody to."
      )
    }
  }
}

/// A reviewer that the review card offers, and why.
public struct ReviewerSuggestion: Codable, Equatable, Sendable {
  /// A login, or `@copilot`, which gh takes for Copilot's review.
  public var login: String
  public var reason: String

  public init(login: String, reason: String) {
    self.login = login
    self.reason = reason
  }
}

/// The reviewers that the review card suggests and the reviewers that a
/// request may name.
public enum ReviewRequests {
  /// gh's name for Copilot's code review in `gh pr edit --add-reviewer`.
  public static let copilot = "@copilot"

  /// GitHub's suggested reviewers for the PR, which GitHub picks from the
  /// people who committed to or reviewed the changed files. The PR's author
  /// is left out, and Copilot comes last.
  public static let suggestionsQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          author { login }
          suggestedReviewers { isAuthor isCommenter reviewer { login } }
        }
      }
    }
    """

  public static func suggestions(from response: JSON) throws -> [ReviewerSuggestion] {
    guard let pr = response["data"]?["repository"]?["pullRequest"], pr != .null else {
      throw APIError("GitHub returned no PR for the suggested reviewers")
    }
    let author = pr["author"]?["login"]?.string
    var seen: Set<String> = []
    let suggested = (pr["suggestedReviewers"]?.array ?? []).compactMap { node -> ReviewerSuggestion? in
      guard let login = node["reviewer"]?["login"]?.string, login != author, seen.insert(login).inserted else {
        return nil
      }
      let committed = node["isAuthor"]?.bool == true
      let reviewed = node["isCommenter"]?.bool == true
      let what =
        committed && reviewed ? "committed to and reviewed" : reviewed ? "reviewed" : "committed to"
      return ReviewerSuggestion(login: login, reason: "\(what) the changed files")
    }
    return suggested + [ReviewerSuggestion(login: copilot, reason: "GitHub Copilot's code review")]
  }

  /// Whether gh can take the text as one reviewer: a GitHub login, an
  /// `org/team` slug, or `@copilot`. The check also keeps the text from
  /// reading as one of gh's flags.
  public static func isValidReviewer(_ text: String) -> Bool {
    text == copilot
      || text.range(of: #"\A[A-Za-z0-9][A-Za-z0-9-]{0,38}(/[A-Za-z0-9][A-Za-z0-9._-]*)?\z"#, options: .regularExpression)
        != nil
  }

  /// The reviewers in text that separates them with commas or spaces, each
  /// once, in order.
  public static func reviewers(in text: String) -> [String] {
    var seen: Set<String> = []
    return text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
      .filter { seen.insert($0).inserted }
  }
}
