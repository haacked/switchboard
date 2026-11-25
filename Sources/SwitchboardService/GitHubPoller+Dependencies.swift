import Foundation
import SwitchboardCore

/// The PRs that each session's open PR waits on: the PR of another session
/// whose head branch is its base, and the PRs that its body's `Depends on`
/// lines name. `plans/session-dependencies.md` in the notes repo describes them.
extension GitHubPoller {
  /// The session's PR as this poller last read it, or as the session's facts
  /// recorded it before the first read. It is nil when `mayRead` refuses the
  /// PR's repo for the session's host.
  private func currentPR(_ s: Watched) -> PullRequest? {
    (tracked[s.id]?.prId.flatMap { prs[$0]?.pr } ?? s.facts.pr).flatMap {
      // A session that another live session's PR was refused for gets no dependencies from that PR.
      let refused =
        s.facts.pr?.id != $0.id && service.prOwner(of: $0.id, besides: s.id, onHost: s.site.hostName) != nil
      return mayRead($0.repo, for: s.site.hostName) && !refused ? $0 : nil
    }
  }

  /// The session's recorded edges whose repo `mayRead` allows for the session's host.
  private func readableEdges(_ s: Watched) -> [Dependency] {
    s.facts.dependencies.filter { mayRead($0.repo, for: s.site.hostName) }
  }

  /// The lookup keys of the PRs that open PRs name in their bodies, and of
  /// the recorded edges that still hold their session, so the poll that
  /// resolves an edge still reads its PR after the edge leaves the body.
  func dependencyKeys(_ sessions: [Watched]) -> Set<PRKey> {
    var keys: Set<PRKey> = []
    for s in sessions {
      if let pr = currentPR(s), pr.state == .open {
        for ref in pr.dependsOn ?? [] where mayRead(ref.repo, for: s.site.hostName) {
          keys.insert(.number(repo: ref.repo, number: ref.number))
        }
      }
      for d in readableEdges(s) where d.holds { keys.insert(.number(repo: d.repo, number: d.number)) }
    }
    return keys
  }

  /// Records each session's edges when they changed. When an edge that the
  /// session recorded as open, or as merged and not yet deployed, has now
  /// resolved, sbd also sends the session a message that says so, through
  /// `dependency-resolved`. A failed send records nothing, so the next poll
  /// sends again.
  ///
  /// GitHub retargets a stacked PR when its base merges and the base branch
  /// is deleted. This poll can read the retarget before it reads the merge.
  /// An edge that left the list while its PR's last read is older than this
  /// poll therefore stays one more poll, which reads that PR at once.
  func recordDependencies(_ sessions: [Watched], now: Int64, stats: inout Stats) {
    let owned = sessions.compactMap { s in currentPR(s).map { (id: s.id, pr: $0) } }
    for s in sessions {
      let pr = currentPR(s)
      let old = s.facts.dependencies
      // `withState` reads the PRs that the poller read for any session. An edge in a repo that the session's host
      // may not read therefore never reaches `withState`.
      let kept = readableEdges(s)
      var edges = pr.map { dependencies(of: s, $0, owned: owned, recorded: kept) } ?? []
      if pr?.state == .open {
        for before in kept
        where before.holds && !edges.contains(where: { $0.same(repo: before.repo, number: before.number) }) {
          guard let read = lastRead(before), read.polled < now,
            withState(before, before: before, host: s.site.hostName).holds
          else {
            continue
          }
          edges.append(before)
          readRequests.readAtNextPoll([read.pr.id], trigger: .wait)
        }
      }
      guard edges != old else { continue }
      var data: [String: JSON] = ["dependencies": (try? JSON(encoding: edges)) ?? []]
      let resolved = kept.filter { $0.holds && $0.state != nil }.compactMap { before -> Dependency? in
        let current =
          edges.first { $0.same(repo: before.repo, number: before.number) }
          ?? withState(before, before: before, host: s.site.hostName)
        return current.resolved ? current : nil
      }
      guard let pr, pr.state == .open, !resolved.isEmpty else {
        event(s.id, "dependencies", .object(data))
        continue
      }
      data["session"] = .string(s.id)
      data["message"] = .string(
        "Switchboard: " + resolved.map { GitHubPoller.resolvedLine($0, pr) }.joined(separator: "\n"))
      let response = service.handle(Request(op: "dependency-resolved", args: .object(data)))
      if response.ok {
        stats.resumed += 1
      } else {
        logLine("github: can't tell \(s.id) that a dependency resolved: \(response.error ?? "")")
      }
    }
  }

  /// The open PR's edges, each with the state of its PR. A `Depends on` line
  /// that names a repo that `mayRead` refuses for the session's host adds no edge.
  private func dependencies(
    of s: Watched, _ pr: PullRequest, owned: [(id: String, pr: PullRequest)], recorded: [Dependency]
  ) -> [Dependency] {
    guard pr.state == .open else { return [] }
    var edges: [Dependency] = []
    if pr.base != pr.defaultBranch {
      let bases = owned.filter { $0.id != s.id && Dependencies.sameRepo($0.pr.repo, pr.repo) && $0.pr.head == pr.base }
      if let base = bases.first(where: { $0.pr.state == .open }) ?? bases.first {
        edges.append(
          Dependency(via: .stack, repo: base.pr.repo, number: base.pr.number, base: pr.base, session: base.id))
      }
    }
    for ref in pr.dependsOn ?? [] where mayRead(ref.repo, for: s.site.hostName) {
      if let i = edges.firstIndex(where: { ref.same(repo: $0.repo, number: $0.number) }) {
        if ref.deploy {
          edges[i].deploy = true
          edges[i].service = ref.service
          edges[i].environments = ref.environments
        }
        continue
      }
      let session = owned.first { ref.same(repo: $0.pr.repo, number: $0.pr.number) }?.id
      edges.append(Dependency(ref: ref, session: session))
    }
    return edges.map { e in
      withState(e, before: recorded.first { $0.same(repo: e.repo, number: e.number) }, host: s.site.hostName)
    }
  }

  /// The edge with its PR's state as this poller last read it. A deploy edge
  /// whose PR merged is deployed once it reached each of its environments,
  /// as `deployState` decides. `before` is the edge as the session recorded it, and `host` is the session's host.
  ///
  /// The poller's reads and comment bodies are in memory, so they are empty
  /// after sbd restarts. An edge whose PR this poller has not read keeps the
  /// recorded state. A merged deploy edge stays deployed once it was, because
  /// its comment body may not have loaded yet. Otherwise a read after a
  /// restart would overwrite the recorded state, and a later read would tell
  /// the session again, or never, that the edge resolved.
  private func withState(_ edge: Dependency, before: Dependency?, host: String?) -> Dependency {
    var d = edge
    guard let read = lastRead(edge) else {
      d.state = before?.state
      d.deployed = d.deploy ? before?.deployed : nil
      d.problem = d.deploy ? before?.problem : nil
      return d
    }
    d.state = read.pr.state
    guard d.deploy, read.pr.state == .merged else {
      d.deployed = nil
      d.problem = nil
      return d
    }
    (d.deployed, d.problem) = deployState(d, read.pr, read.comments, before: before, host: host)
    return d
  }

  /// Whether a merged deploy edge's PR reached its environments, and why it
  /// can't when it can't. An edge that the session recorded as deployed stays
  /// deployed. A named service's state file decides it. Without a service,
  /// the deploy comment decides a PostHog/posthog PR, and nothing that sbd
  /// reads shows a PR in another repository deploy. A service's state file is in the charts repo, so it decides
  /// nothing for a session on a host whose `repos` don't list that repo.
  private func deployState(
    _ d: Dependency, _ pr: PullRequest, _ comments: [PRComment], before: Dependency?, host: String?
  ) -> (deployed: Bool, problem: String?) {
    if before?.state == .merged && before?.deployed == true { return (true, nil) }
    guard let service = d.service else {
      if Dependencies.sameRepo(pr.repo, Wait.posthogRepository) {
        return (deployed(comments, to: d.deployEnvironments), nil)
      }
      return (
        false,
        "Switchboard has no deploy signal for \(pr.repo); name the \(Wait.chartsRepository) service that deploys it with `service: <name>` on the Depends on line"
      )
    }
    let id = GitHubPoller.edgeTargetId(d)
    guard mayRead(Wait.chartsRepository, for: host), let since = deploys.firstSeen[id],
      let read = serviceRead(service, id: id, since: since)
    else {
      return (false, before?.problem)
    }
    switch ServiceDeployVerdict.of(
      service: service, read.state, pr: pr, environments: d.deployEnvironments, progress: read.progress)
    {
    case .deployed?: return (true, nil)
    case .stuck(let reason)?: return (false, reason)
    case nil: return (false, nil)
    }
  }

  /// The merged PRs that deploy edges with a service wait on, from the open
  /// PRs' `Depends on` lines and from the recorded edges that still hold. A
  /// line whose recorded edge resolved needs no more checks. A session on a host whose `repos` don't list the
  /// charts repo adds none.
  func edgeDeployTargets(_ sessions: [Watched], now: Int64) -> [DeployTarget] {
    var edges: [Dependency] = []
    for s in sessions where mayRead(Wait.chartsRepository, for: s.site.hostName) {
      let recorded = s.facts.dependencies
      if let pr = currentPR(s), pr.state == .open {
        edges += (pr.dependsOn ?? []).filter { ref in
          !recorded.contains { $0.resolved && ref.same(repo: $0.repo, number: $0.number) }
        }.map { Dependency(ref: $0) }
      }
      edges += recorded.filter(\.holds)
    }
    var targets: [String: DeployTarget] = [:]
    for d in edges where d.deploy {
      guard let service = d.service, let pr = lastRead(d)?.pr, pr.state == .merged, let merge = pr.mergeCommit else {
        continue
      }
      let id = GitHubPoller.edgeTargetId(d)
      let since = deploys.firstSeen[id] ?? now
      deploys.firstSeen[id] = since
      targets[id] = DeployTarget(
        id: id, service: service, pr: pr, merge: merge, environments: d.deployEnvironments, since: since)
    }
    return targets.values.sorted { $0.id < $1.id }
  }

  static func edgeTargetId(_ d: Dependency) -> String {
    "edge \(d.service ?? "") \(d.repo.lowercased())#\(d.number) "
      + d.deployEnvironments.map(\.rawValue).joined(separator: ",")
  }

  private func lastRead(_ edge: Dependency) -> CachedPR? {
    prs.values.first { edge.same(repo: $0.pr.repo, number: $0.pr.number) }
  }

  static func resolvedLine(_ d: Dependency, _ pr: PullRequest) -> String {
    let label = d.label(from: pr.repo)
    if d.deploy {
      return "\(label) deployed to \(d.environmentsText), so #\(pr.number) no longer waits on it."
    }
    if d.via == .stack { return "\(label) merged; retarget and rebase #\(pr.number)." }
    return "\(label) merged, so #\(pr.number) no longer waits on it."
  }
}
