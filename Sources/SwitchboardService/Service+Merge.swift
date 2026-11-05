import Foundation
import SwitchboardCore

extension Service {
  static let mergeTimeoutSeconds = 120.0

  /// The `merge` request, which merges a Ready to merge session's PR with a
  /// merge commit, or with `dismiss` takes the session out of Ready to merge
  /// until its PR's head commit changes. `session` names the session, or `pr`
  /// and an optional `repository` name it by its open PR. After a merge, sbd
  /// resumes the session with a message. A failed merge records gh's error
  /// and fails the request. It changes nothing else.
  func mergeRequest(_ args: JSON) throws -> JSON {
    let (id, pr): (String, PullRequest?) = try queue.sync {
      let id = try mergeTarget(args)
      let e = entries[id]!
      let verdict = Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: lastState)
      guard verdict.state == .readyToMerge, let pr = e.facts.pr else {
        throw APIError("\(e.session.name) isn't ready to merge: \(verdict.reason)")
      }
      guard !merging.contains(id) else { throw APIError("#\(pr.number) is already merging") }
      if args["dismiss"]?.bool == true {
        record(id, "merge", try JSON(encoding: MergeAttempt(head: pr.headSha, result: .dismissed)))
        return (id, nil)
      }
      merging.insert(id)
      return (id, pr)
    }
    guard let pr else {
      return try queue.sync {
        guard entries[id] != nil else { throw APIError("\(id) was removed") }
        return try JSON(encoding: summary(id))
      }
    }
    defer { queue.sync { _ = merging.remove(id) } }
    let error = runMerge(pr)
    return try queue.sync {
      let attempt = MergeAttempt(head: pr.headSha, result: error == nil ? .merged : .failed, error: error)
      record(id, "merge", try JSON(encoding: attempt))
      if let error { throw APIError("#\(pr.number) didn't merge: \(error)") }
      if entries[id]?.session.done == false {
        _ = try send(id, "PR #\(pr.number) merged; finish the post-merge steps", byUser: false)
      }
      return try JSON(encoding: summary(id))
    }
  }

  /// The session that `session` names, or the one whose open PR has the
  /// number `pr`, in the repository `repository` when it is set.
  private func mergeTarget(_ args: JSON) throws -> String {
    guard let number = args["pr"]?.int else { return try lookup(args) }
    let repository = args["repository"]?.string
    let matches = entries.values.filter { e in
      guard let pr = e.facts.pr, pr.number == number, pr.state == .open else { return false }
      return repository.map { Dependencies.sameRepo($0, pr.repo) } ?? true
    }
    .map(\.session).sorted { $0.id < $1.id }
    let ref = Wait.PullRequest(repository: repository, number: number).text
    guard matches.count == 1 else {
      if matches.isEmpty { throw APIError("no session has an open PR \(ref)") }
      throw APIError(
        "\(matches.count) sessions have an open PR \(ref), so name one: "
          + matches.map { "\($0.name) (\($0.id))" }.joined(separator: ", "))
    }
    return matches[0].id
  }

  /// Runs `gh pr merge` and returns its error, or nil when it merged.
  /// `--match-head-commit` makes GitHub refuse the merge when a push landed
  /// after the session became Ready to merge.
  private func runMerge(_ pr: PullRequest) -> String? {
    guard let gh = findExecutable(config.github.gh) else { return "can't find \(config.github.gh)" }
    let args = [
      "pr", "merge", String(pr.number), "--repo", pr.repo, "--merge", "--match-head-commit", pr.headSha,
    ]
    do {
      let r = try runCommand(gh, args, timeout: Service.mergeTimeoutSeconds)
      if r.status == 0 { return nil }
      let text = [r.stderr, r.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
      return text ?? "gh pr merge exited with status \(r.status)"
    } catch {
      return "\(error)"
    }
  }
}
