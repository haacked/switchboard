import Foundation
import SwitchboardCore

extension Service {
  static let reviewTimeoutSeconds = 60.0

  /// The `review` request for a session that shows the review card. Without
  /// `reviewers`, it returns the suggested reviewers. With `reviewers`, it
  /// runs `gh pr edit --add-reviewer` and records the attempt. A failed
  /// request records gh's error and fails. With `dismiss`, it hides the card
  /// until the PR's head commit changes. `session` names the session, or `pr`
  /// and an optional `repository` name it by its open PR.
  func reviewRequest(_ args: JSON) throws -> JSON {
    let dismiss = args["dismiss"]?.bool == true
    let reviewers = args["reviewers"]?.array.map { $0.compactMap(\.string) }
    if let reviewers {
      if dismiss { throw APIError("review takes reviewers or dismiss, not both") }
      if reviewers.isEmpty { throw APIError("name at least one reviewer") }
      if let bad = reviewers.first(where: { !ReviewRequests.isValidReviewer($0) }) {
        throw APIError("\"\(bad)\" is not a GitHub login, an org/team, or \(ReviewRequests.copilot)")
      }
    }
    let (id, pr, dismissed) = try queue.sync { () -> (String, PullRequest, JSON?) in
      let id = try sessionByPR(args)
      let e = entries[id]!
      let verdict = Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: lastState)
      guard verdict.options.contains(where: { $0.action == .requestReview }), let pr = e.facts.pr else {
        throw APIError("\(e.session.name) isn't ready for a review request: \(verdict.reason)")
      }
      if dismiss {
        let attempt = ReviewRequestAttempt(head: pr.headSha, result: .dismissed)
        record(id, ReviewRequestAttempt.event, try JSON(encoding: attempt))
        return (id, pr, try JSON(encoding: summary(id)))
      }
      if reviewers != nil, !requestingReview.insert(id).inserted {
        throw APIError("#\(pr.number) already has a review request running")
      }
      return (id, pr, nil)
    }
    if let dismissed { return dismissed }
    guard let reviewers else {
      return [
        "session": .string(id), "pr": .number(Double(pr.number)),
        "suggestions": try JSON(encoding: try suggestReviewers(pr)),
      ]
    }
    defer { queue.sync { _ = requestingReview.remove(id) } }
    let error = runReviewRequest(pr, reviewers)
    return try queue.sync {
      guard entries[id] != nil else { throw APIError("\(id) was removed") }
      let attempt = ReviewRequestAttempt(
        head: pr.headSha, result: error == nil ? .requested : .failed, reviewers: reviewers, error: error)
      record(id, ReviewRequestAttempt.event, try JSON(encoding: attempt))
      if let error { throw APIError("#\(pr.number) has no review request: \(error)") }
      return try JSON(encoding: summary(id))
    }
  }

  /// GitHub's suggested reviewers for the PR, read with `gh api graphql`, and
  /// Copilot. `-f` keeps the node id a string.
  private func suggestReviewers(_ pr: PullRequest) throws -> [ReviewerSuggestion] {
    let output = try runGh(
      ["api", "graphql", "-f", "id=\(pr.id)", "-f", "query=\(ReviewRequests.suggestionsQuery)"],
      timeout: Service.reviewTimeoutSeconds)
    guard let json = JSON.parse(output) else { throw APIError("gh api graphql printed no JSON") }
    return try ReviewRequests.suggestions(from: json)
  }

  /// Runs `gh pr edit --add-reviewer` and returns its error, or nil when it
  /// requested the review.
  private func runReviewRequest(_ pr: PullRequest, _ reviewers: [String]) -> String? {
    do {
      _ = try runGh(
        ["pr", "edit", String(pr.number), "--repo", pr.repo, "--add-reviewer", reviewers.joined(separator: ",")],
        timeout: Service.reviewTimeoutSeconds)
      return nil
    } catch {
      return "\(error)"
    }
  }
}
