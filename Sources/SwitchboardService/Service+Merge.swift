import Foundation
import SwitchboardCore

extension Service {
  static let mergeTimeoutSeconds = 120.0

  /// The `merge` request, which lands a Ready to merge session's PR the way
  /// its repository merges: a merge commit, GitHub's merge queue, or Trunk's
  /// queue. With `dismiss` it acknowledges the session's Ready to merge
  /// item. `session` names the session, or `pr` and
  /// an optional `repository` name it by its open PR. After a merge, sbd
  /// resumes the session with a message. After an enqueue, sbd sets a queue
  /// wait that resumes the session when the PR merges. A failed command
  /// records its error and fails the request. It changes nothing else. It
  /// refuses a session that the removal job holds or whose files `rm` or
  /// `cleanup` is removing.
  func mergeRequest(_ args: JSON) throws -> JSON {
    let (id, pr, method): (String, PullRequest?, MergeMethod) = try queue.sync {
      let id = try sessionByPR(args)
      let name = entries[id]!.session.name
      let (e, verdict): (Entry, Verdict)
      switch mergeAdmission(id) {
      case .busy(let refusal): throw refusal
      case .notReady(let v): throw APIError("\(name) isn't ready to merge: \(v.reason)")
      case .ready(let entry, let v): (e, verdict) = (entry, v)
      }
      guard let pr = e.facts.pr else { throw APIError("\(name) isn't ready to merge: \(verdict.reason)") }
      let method = e.facts.mergeMethod
      if args["dismiss"]?.bool == true {
        try acknowledge(id, verdict)
        return (id, nil, method)
      }
      guard method != .unknown else {
        throw APIError("can't tell how \(pr.repo) merges, so merge #\(pr.number) on GitHub")
      }
      merging.insert(id)
      return (id, pr, method)
    }
    guard let pr else {
      return try queue.sync {
        guard entries[id] != nil else { throw APIError("\(id) was removed") }
        return try JSON(encoding: summary(id))
      }
    }
    defer { queue.sync { _ = merging.remove(id) } }
    _ = try landPR(id, pr: pr, method: method)
    return try queue.sync { try JSON(encoding: summary(id)) }
  }

  /// Whether the session may start a merge.
  enum MergeAdmission {
    case busy(APIError)
    case notReady(Verdict)
    case ready(Entry, Verdict)
  }

  /// Checks in this order: the session is gone, being deleted, or already merging; it is not Ready to merge; it is
  /// ready. The caller inserts a ready session in `merging`. It runs on the state queue.
  func mergeAdmission(_ id: String) -> MergeAdmission {
    guard let e = entries[id] else { return .busy(APIError("\(id) was removed")) }
    if let refusal = beingDeletedRefusal(id) { return .busy(refusal) }
    if merging.contains(id) {
      return .busy(APIError("\(e.facts.pr.map { "#\($0.number)" } ?? e.session.name) is already merging"))
    }
    let verdict = Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: lastState)
    return verdict.state == .readyToMerge ? .ready(e, verdict) : .notReady(verdict)
  }

  /// Merges or enqueues the session's PR by `method` and records a `merge` event with the attempt.
  ///
  /// After a merge it resumes the session with a message. After an enqueue it sets a queue wait. A session marked
  /// done gets neither. A failed command throws its error after the record. The caller must not hold the state
  /// queue, because the gh command runs outside it.
  func landPR(_ id: String, pr: PullRequest, method: MergeMethod) throws -> MergeAttempt {
    let error: String?
    if GitLab.isMR(pr.id) {
      error = runGitLabMerge(pr)
    } else if method == .trunk {
      error = runTrunkEnqueue(pr)
    } else {
      error = runMerge(pr)
    }
    return try queue.sync {
      let landed: MergeAttempt.Result = method.enqueues ? .enqueued : .merged
      let attempt = MergeAttempt(head: pr.headSha, result: error == nil ? landed : .failed, error: error)
      record(id, "merge", try JSON(encoding: attempt))
      if let error { throw APIError("#\(pr.number) didn't \(method.verb.lowercased()): \(error)") }
      if entries[id]?.session.done == false {
        if method.enqueues {
          try waitForQueue(id, pr)
        } else {
          _ = try send(id, "PR #\(pr.number) merged; finish the post-merge steps", by: .sbd, trigger: .merge)
        }
      }
      return attempt
    }
  }

  /// Sets the wait that keeps an enqueued session in Waiting until its PR
  /// merges or closes, or Trunk removes it from its queue. The GitHub poller
  /// resolves it and resumes the session.
  private func waitForQueue(_ id: String, _ pr: PullRequest) throws {
    let args: JSON = [
      "session": .string(id), "kind": .string(Wait.Kind.queue.rawValue), "target": .string("\(pr.repo)#\(pr.number)"),
      "note": "enqueued; once it merges, finish the post-merge steps", "by": .string(Author.you.rawValue),
    ]
    _ = try waitRequest("wait", args, caller: .inProcess)
  }

  /// The session that `session` names, or the one whose open PR has the
  /// number `pr`, in the repository `repository` when it is set.
  func sessionByPR(_ args: JSON) throws -> String {
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
          + matches.map(\.mention).joined(separator: ", "))
    }
    return matches[0].id
  }

  /// Merges the merge request through GitLab's API and returns the error, or
  /// nil when GitLab merged it. The request names the head commit, so a push
  /// that landed after the session became Ready to merge is refused.
  private func runGitLabMerge(_ pr: PullRequest) -> String? {
    guard let github else { return "GitLab isn't configured" }
    do {
      try github.mergeGitLab(pr)
      return nil
    } catch {
      return "\(error)"
    }
  }

  /// Runs `gh pr merge` and returns its error, or nil when it merged or
  /// GitHub added the PR to the base branch's merge queue.
  /// `--match-head-commit` makes GitHub refuse the merge when a push landed
  /// after the session became Ready to merge.
  private func runMerge(_ pr: PullRequest) -> String? {
    ghError(
      ["pr", "merge", String(pr.number), "--repo", pr.repo, "--merge", "--match-head-commit", pr.headSha],
      timeout: Service.mergeTimeoutSeconds)
  }

  /// Comments `/trunk merge` on the PR, which adds it to Trunk's queue, and
  /// returns gh's error, or nil when the comment posted.
  private func runTrunkEnqueue(_ pr: PullRequest) -> String? {
    ghError(
      ["pr", "comment", String(pr.number), "--repo", pr.repo, "--body", "/trunk merge"],
      timeout: Service.mergeTimeoutSeconds)
  }
}
