import Foundation
import SwitchboardCore

extension Service {
  static let reviewTimeoutSeconds = 60.0

  /// The `review` request for a session that shows the review card. Without
  /// `reviewers`, it returns the suggested reviewers. With `reviewers`, it
  /// runs `gh pr edit --add-reviewer` and records the attempt, and a failed
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
    let (id, pr) = try queue.sync { () -> (String, PullRequest) in
      let id = try sessionByPR(args)
      let e = entries[id]!
      let verdict = Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: lastState)
      guard verdict.options.contains(where: { $0.action == .requestReview }), let pr = e.facts.pr else {
        throw APIError("\(e.session.name) isn't ready for a review request: \(verdict.reason)")
      }
      if dismiss {
        record(id, ReviewRequestAttempt.event, try JSON(encoding: ReviewRequestAttempt(head: pr.headSha, result: .dismissed)))
      } else if reviewers != nil {
        guard requestingReview.insert(id).inserted else { throw APIError("#\(pr.number) already has a review request running") }
      }
      return (id, pr)
    }
    if dismiss { return try queue.sync { try JSON(encoding: summary(id)) } }
    guard let reviewers else {
      let suggestions = try suggestReviewers(pr)
      return ["session": .string(id), "pr": .number(Double(pr.number)), "suggestions": try JSON(encoding: suggestions)]
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

  /// GitHub's suggested reviewers for the PR, read with `gh api graphql`, and Copilot.
  private func suggestReviewers(_ pr: PullRequest) throws -> [ReviewerSuggestion] {
    let parts = pr.repo.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { throw APIError("can't read the owner and name of \(pr.repo)") }
    let args = [
      "api", "graphql", "-F", "owner=\(parts[0])", "-F", "name=\(parts[1])", "-F", "number=\(pr.number)", "-f",
      "query=\(ReviewRequests.suggestionsQuery)",
    ]
    let output = try runGh(args)
    guard let json = JSON.parse(output) else { throw APIError("gh api graphql printed no JSON") }
    return try ReviewRequests.suggestions(from: json)
  }

  /// Runs `gh pr edit --add-reviewer` and returns its error, or nil when it
  /// requested the review.
  private func runReviewRequest(_ pr: PullRequest, _ reviewers: [String]) -> String? {
    do {
      _ = try runGh([
        "pr", "edit", String(pr.number), "--repo", pr.repo, "--add-reviewer", reviewers.joined(separator: ","),
      ])
      return nil
    } catch {
      return "\(error)"
    }
  }

  /// Runs gh and returns its stdout. A non-zero exit throws gh's error.
  private func runGh(_ args: [String]) throws -> String {
    guard let gh = findExecutable(config.github.gh) else { throw APIError("can't find \(config.github.gh)") }
    let r = try runCommand(gh, args, timeout: Service.reviewTimeoutSeconds)
    guard r.status == 0 else {
      let text = [r.stderr, r.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
      throw APIError(text ?? "gh \(args.prefix(2).joined(separator: " ")) exited with status \(r.status)")
    }
    return r.stdout
  }
}
