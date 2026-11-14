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
      waits.compactMap { w in w.wait.pr.map { (pr: $0, session: Optional(w.session)) } }
      + merges.map { (pr: $0, session: nil) }
    return Interest(waits: waits, merges: merges, keys: Set(named.compactMap { key(of: $0.pr, session: $0.session) }))
  }

  /// The key of the PR, or nil when `mayRead` refuses its repo for the session's host. A PR without a repo takes
  /// the session's repo, which the box can change at any time. The check therefore runs at each poll.
  private func key(of pr: Wait.PullRequest, session: Session?) -> PRKey? {
    guard let repo = pr.repository ?? session.flatMap({ ownRepository($0.id) }), mayRead(repo, for: session?.host)
    else { return nil }
    return .number(repo: repo, number: pr.number)
  }

  private func ownRepository(_ session: String) -> String? {
    guard let t = tracked[session] else { return nil }
    return (t.branch.key ?? t.transcript.link)?.repo ?? t.prId.flatMap { prs[$0]?.pr.repo }
  }

  /// The node id of the PR that a wait is about.
  func prId(of wait: Wait, session: Session) -> String? {
    guard let pr = wait.pr else { return tracked[session.id]?.prId }
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
      guard let id = prId(of: wait, session: session) else { continue }
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
  /// - a `ci` outcome that only one read showed, since a read just after a
  ///   push can show the old head commit, or a status that reports before CI
  ///   queues. Two reads that both show a failure agree. One read is enough
  ///   when `Settled.mayResolveOnOneRead` holds and an Actions read of the
  ///   head commit shows a finished run (`ActionsRead.showsFinishedRun`).
  /// - a GitHub merge queue removal that only one read showed, since a read
  ///   while GitHub merges the PR can show it outside the queue before it
  ///   shows it merged.
  func resolveWaits(_ interest: Interest, stats: inout Stats) {
    confirming = confirming.filter { id, _ in interest.waits.contains { $0.wait.id == id } }
    queuedWaits = queuedWaits.filter { id in interest.waits.contains { $0.wait.id == id } }
    let settled = interest.waits.compactMap { session, wait -> Settled? in
      guard let id = prId(of: wait, session: session), let read = prs[id], read.polled >= wait.created,
        case let comments = keptComments(read.comments), let pr = shown(id, last: nil),
        let outcome = wait.kind == .deploy
          ? deployOutcome(wait, pr, comments, host: session.host)
          : wait.resolution(of: pr) ?? githubQueueOutcome(wait, pr),
        !(wait.pr == nil && wait.finishedBeforeItCounts(pr))
      else { return nil }
      return Settled(session: session.id, wait: wait, prId: id, pr: pr, outcome: outcome, polled: read.polled)
    }
    let actions = readActions(settled, stats: &stats)
    for s in settled {
      guard confirmed(s, actions: actions[s.prId]),
        !service.queue.sync(execute: { service.entries[s.session]?.session.done ?? true })
      else { continue }
      do {
        _ = try service.resolveWait(session: s.session, wait: s.wait.id, outcome: s.outcome)
        stats.resolved += 1
      } catch {
        logLine("github: can't resolve wait \(s.wait.id) of \(s.session): \(error)")
      }
    }
    for pr in interest.merges {
      guard let key = key(of: pr, session: nil), let id = targets[key]?.prId, prs[id]?.pr.state == .merged else {
        continue
      }
      stats.merged += service.pullRequestMerged(pr).count
    }
  }

  /// A wait that its PR's last read settles, before `confirmed` checks it.
  private struct Settled {
    var session: String
    var wait: Wait
    var prId: String
    var pr: PullRequest
    var outcome: String
    var polled: Int64

    /// Whether the PR's head is the commit that the `ci` wait recorded, and
    /// the read came at least `window` after the wait was set. GitHub adds an
    /// event's Actions suites a few seconds after the event, so a read soon
    /// after marking a draft ready can show only an earlier run's suites.
    func mayResolveOnOneRead(window: Int64) -> Bool {
      wait.kind == .ci && wait.headSha == pr.headSha && GitHub.elapsed(since: wait.created, window, now: polled)
    }
  }

  /// Reads the GitHub Actions suites of each PR on which a settled `ci` wait
  /// may resolve on one read. A wait that `confirming` holds at that head
  /// had its Actions read on an earlier poll, so the two-read rule settles it
  /// without another. A PR whose read fails is left out, so its waits need two
  /// reads.
  private func readActions(_ settled: [Settled], stats: inout Stats) -> [String: ActionsRead] {
    let ids = Set(
      settled.filter {
        $0.mayResolveOnOneRead(window: settings.pendingMs) && confirming[$0.wait.id]?.sha != $0.pr.headSha
      }.map(\.prId))
    var reads: [String: ActionsRead] = [:]
    for chunk in GitHub.chunks(ids.sorted()) {
      do {
        let response = try request(GitHub.actionsQuery, idsVariable(chunk), stats: &stats)
        for (id, read) in (response["data"]?["nodes"]?.array ?? []).compactMap(GitHub.parseActions) {
          reads[id] = read
        }
      } catch {
        logLine("github: can't read the Actions suites: \(error)")
      }
    }
    return reads
  }

  static let leftGitHubQueue = "GitHub removed it from the merge queue"

  /// `leftGitHubQueue` for a `queue` wait whose open PR an earlier read showed
  /// in GitHub's merge queue and this read shows outside it. A PR that the
  /// queue has not taken yet keeps the wait open.
  private func githubQueueOutcome(_ wait: Wait, _ pr: PullRequest) -> String? {
    guard wait.kind == .queue, pr.state == .open, pr.queue == nil else { return nil }
    if pr.inMergeQueue == true { queuedWaits.insert(wait.id) }
    guard pr.inMergeQueue == false, queuedWaits.contains(wait.id) else { return nil }
    return Self.leftGitHubQueue
  }

  private func confirmed(_ s: Settled, actions: ActionsRead?) -> Bool {
    let (wait, pr, outcome) = (s.wait, s.pr, s.outcome)
    guard wait.kind == .ci || outcome == Self.leftGitHubQueue else { return true }
    if s.mayResolveOnOneRead(window: settings.pendingMs), actions?.showsFinishedRun(of: pr) == true { return true }
    // More Depot jobs can fail between the two reads. That changes the
    // outcome's words but not the fact that the checks failed.
    let verdict = wait.kind == .ci && pr.ciFailed ? "failed" : outcome
    guard let first = confirming[wait.id], first.sha == pr.headSha, first.outcome == verdict else {
      confirming[wait.id] = (pr.headSha, verdict, s.polled)
      return false
    }
    return s.polled > first.polled
  }
}
