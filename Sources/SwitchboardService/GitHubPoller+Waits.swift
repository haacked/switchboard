import Foundation
import SwitchboardCore

/// What the PR kinds of waits and the merge triggers of follow-ups need from a
/// poll.
extension GitHubPoller {
  static let waitKinds: Set<Wait.Kind> = [.ci, .review, .botReview, .approval, .merge, .queue, .deploy]

  /// The open waits that the poller resolves, the PRs that follow-ups wait to
  /// see merge, and the lookup key of each PR they name.
  struct Interest {
    var waits: [(session: Session, wait: Wait)]
    var merges: [Wait.PullRequest]
    var keys: Set<PRKey>
  }

  /// Reads the open waits and the follow-up PRs from the service. A PR with no
  /// repository belongs to the session's own repository, which the session's
  /// branch, transcript link, or PR names. When none does, the wait stays open.
  func interests() -> Interest {
    let waits = service.openWaits(GitHubPoller.waitKinds)
    var seen: Set<String> = []
    let merges = service.followupPullRequests().filter { seen.insert($0.text.lowercased()).inserted }
    let named =
      waits.compactMap { w in w.wait.pr.map { (pr: $0, session: Optional(w.session.id)) } }
      + merges.map { (pr: $0, session: nil) }
    return Interest(waits: waits, merges: merges, keys: Set(named.compactMap { key(of: $0.pr, session: $0.session) }))
  }

  private func key(of pr: Wait.PullRequest, session: String?) -> PRKey? {
    guard let repo = pr.repository ?? session.flatMap(ownRepository) else { return nil }
    return .number(repo: repo, number: pr.number)
  }

  private func ownRepository(_ session: String) -> String? {
    guard let t = tracked[session] else { return nil }
    switch t.branch.key ?? t.transcript.link {
    case .branch(let repo, _, _)?, .number(let repo, _)?: return repo
    case nil: return t.prId.flatMap { prs[$0]?.pr.repo }
    }
  }

  /// The node id of the PR that a wait is about.
  func prId(of wait: Wait, session: String) -> String? {
    guard let pr = wait.pr else { return tracked[session]?.prId }
    return key(of: pr, session: session).flatMap { targets[$0]?.prId }
  }

  /// For each PR that an open wait is about, when the newest such wait was
  /// set, and the PRs that one of those waits needs read at the pending rate.
  struct Waited {
    var created: [String: Int64] = [:]
    var pending: Set<String> = []
  }

  func waitedOn(_ interest: Interest) -> Waited {
    var waited = Waited()
    for (session, wait) in interest.waits {
      guard let id = prId(of: wait, session: session.id) else { continue }
      waited.created[id] = max(waited.created[id] ?? 0, wait.created)
      if wait.readsPRWhilePending(prs[id]?.pr) { waited.pending.insert(id) }
    }
    return waited
  }

  /// Resolves each wait that its PR's last read settles, then tells the service
  /// about the follow-up PRs that merged. This runs on the poller's queue, as
  /// `resolveWait` requires. A wait doesn't resolve from:
  /// - a read from before the wait was set;
  /// - a session marked done since the poll began;
  /// - the session's own PR when it finished before the wait was set, which is
  ///   an earlier PR of a reused branch;
  /// - a `ci` outcome that only one read showed, since a read just after a push
  ///   can show the old head commit, or a status that reports before CI queues.
  ///   Two reads that both show a failure agree.
  /// - a GitHub merge queue removal that only one read showed.
  func resolveWaits(_ interest: Interest, stats: inout Stats) {
    confirming = confirming.filter { id, _ in interest.waits.contains { $0.wait.id == id } }
    queuedWaits = queuedWaits.filter { id in interest.waits.contains { $0.wait.id == id } }
    for (session, wait) in interest.waits {
      guard let id = prId(of: wait, session: session.id), let read = prs[id], read.polled >= wait.created,
        case let comments = keptComments(read.comments), let pr = shown(id, last: nil),
        let outcome = wait.kind == .deploy
          ? deployOutcome(wait, pr, comments) : wait.resolution(of: pr) ?? githubQueueOutcome(wait, pr),
        !(wait.pr == nil && wait.finishedBeforeSet(pr)),
        confirmed(wait, pr, outcome, polled: read.polled),
        !service.queue.sync(execute: { service.entries[session.id]?.session.done ?? true })
      else { continue }
      do {
        _ = try service.resolveWait(session: session.id, wait: wait.id, outcome: outcome)
        stats.resolved += 1
      } catch {
        logLine("github: can't resolve wait \(wait.id) of \(session.id): \(error)")
      }
    }
    for pr in interest.merges {
      guard let key = key(of: pr, session: nil), let id = targets[key]?.prId, prs[id]?.pr.state == .merged else {
        continue
      }
      stats.merged += service.pullRequestMerged(pr).count
    }
  }

  /// "GitHub removed it from the merge queue" for a `queue` wait whose open
  /// PR an earlier read showed in GitHub's merge queue and this read shows
  /// outside it. A PR that the queue has not taken yet keeps the wait open.
  private func githubQueueOutcome(_ wait: Wait, _ pr: PullRequest) -> String? {
    guard wait.kind == .queue, pr.state == .open, pr.queue == nil else { return nil }
    if pr.inMergeQueue == true { queuedWaits.insert(wait.id) }
    guard pr.inMergeQueue == false, queuedWaits.contains(wait.id) else { return nil }
    return "GitHub removed it from the merge queue"
  }

  private func confirmed(_ wait: Wait, _ pr: PullRequest, _ outcome: String, polled: Int64) -> Bool {
    let leftGitHubQueue = wait.kind == .queue && pr.state == .open && pr.queue == nil
    guard wait.kind == .ci || leftGitHubQueue else { return true }
    // More Depot jobs can fail between the two reads. That changes the
    // outcome's words but not the fact that the checks failed.
    let verdict = wait.kind == .ci && pr.ciFailed ? "failed" : outcome
    guard let first = confirming[wait.id], first.sha == pr.headSha, first.outcome == verdict else {
      confirming[wait.id] = (pr.headSha, verdict, polled)
      return false
    }
    return polled > first.polled
  }
}
