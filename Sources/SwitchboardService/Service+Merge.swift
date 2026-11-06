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
  /// records its error and fails the request. It changes nothing else.
  func mergeRequest(_ args: JSON) throws -> JSON {
    let (id, pr, method): (String, PullRequest?, MergeMethod) = try queue.sync {
      let id = try sessionByPR(args)
      let e = entries[id]!
      let verdict = Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: lastState)
      guard verdict.state == .readyToMerge, let pr = e.facts.pr else {
        throw APIError("\(e.session.name) isn't ready to merge: \(verdict.reason)")
      }
      guard !merging.contains(id) else { throw APIError("#\(pr.number) is already merging") }
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
    let error = method == .trunk ? runTrunkEnqueue(pr) : runMerge(pr)
    return try queue.sync {
      let landed: MergeAttempt.Result = method.enqueues ? .enqueued : .merged
      let attempt = MergeAttempt(head: pr.headSha, result: error == nil ? landed : .failed, error: error)
      record(id, "merge", try JSON(encoding: attempt))
      if let error { throw APIError("#\(pr.number) didn't \(method.verb.lowercased()): \(error)") }
      if entries[id]?.session.done == false {
        if method.enqueues {
          try waitForQueue(id, pr)
        } else {
          _ = try send(id, "PR #\(pr.number) merged; finish the post-merge steps", byUser: false)
        }
      }
      return try JSON(encoding: summary(id))
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
    _ = try waitRequest("wait", args)
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
          + matches.map { "\($0.name) (\($0.id))" }.joined(separator: ", "))
    }
    return matches[0].id
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

  /// Runs gh and returns its error, or nil when it exited 0.
  func ghError(_ args: [String], timeout: TimeInterval) -> String? {
    do {
      _ = try runGh(args, timeout: timeout)
      return nil
    } catch {
      return "\(error)"
    }
  }

  /// Runs gh and returns its stdout. A non-zero exit throws gh's error, or
  /// its exit status when it printed nothing.
  func runGh(_ args: [String], timeout: TimeInterval) throws -> String {
    guard let gh = findExecutable(config.github.gh) else { throw APIError("can't find \(config.github.gh)") }
    let r = try runCommand(gh, args, timeout: timeout)
    guard r.status == 0 else {
      let text = [r.stderr, r.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
      throw APIError(text ?? "gh \(args.prefix(2).joined(separator: " ")) exited with status \(r.status)")
    }
    return r.stdout
  }
}
