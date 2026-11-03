import Foundation
import SwitchboardCore

/// The PRs that each session's open PR waits on: the PR of another session
/// whose head branch is its base, and the PRs that its body's `Depends on`
/// lines name. `plans/session-dependencies.md` in the notes repo describes them.
extension GitHubPoller {
  /// The session's PR as this poller last read it, or as the session's facts
  /// recorded it before the first read.
  private func currentPR(_ s: Watched) -> PullRequest? {
    tracked[s.id]?.prId.flatMap { prs[$0]?.pr } ?? s.facts.pr
  }

  /// The lookup keys of the PRs that open PRs name in their bodies, and of
  /// the recorded edges that still hold their session, so the poll that
  /// resolves an edge still reads its PR after the edge leaves the body.
  func dependencyKeys(_ sessions: [Watched]) -> Set<PRKey> {
    var keys: Set<PRKey> = []
    for s in sessions {
      if let pr = currentPR(s), pr.state == .open {
        for ref in pr.dependsOn ?? [] { keys.insert(.number(repo: ref.repo, number: ref.number)) }
      }
      for d in s.facts.dependencies where d.holds { keys.insert(.number(repo: d.repo, number: d.number)) }
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
    recheck = []
    for s in sessions {
      let pr = currentPR(s)
      let old = s.facts.dependencies
      var edges = pr.map { dependencies(of: s.id, $0, owned: owned, recorded: old) } ?? []
      if pr?.state == .open {
        for before in old
        where before.holds && !edges.contains(where: { $0.same(repo: before.repo, number: before.number) }) {
          guard let read = lastRead(before), read.polled < now, withState(before, recorded: old).holds else { continue }
          edges.append(before)
          recheck.insert(read.pr.id)
        }
      }
      guard edges != old else { continue }
      var data: [String: JSON] = ["dependencies": (try? JSON(encoding: edges)) ?? []]
      let resolved = old.filter { $0.holds && $0.state != nil }.compactMap { before -> Dependency? in
        let current =
          edges.first { $0.same(repo: before.repo, number: before.number) } ?? withState(before, recorded: old)
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

  /// The open PR's edges, each with the state of its PR.
  private func dependencies(
    of id: String, _ pr: PullRequest, owned: [(id: String, pr: PullRequest)], recorded: [Dependency]
  ) -> [Dependency] {
    guard pr.state == .open else { return [] }
    var edges: [Dependency] = []
    if pr.base != pr.defaultBranch {
      let bases = owned.filter { $0.id != id && Dependencies.sameRepo($0.pr.repo, pr.repo) && $0.pr.head == pr.base }
      if let base = bases.first(where: { $0.pr.state == .open }) ?? bases.first {
        edges.append(
          Dependency(via: .stack, repo: base.pr.repo, number: base.pr.number, base: pr.base, session: base.id))
      }
    }
    for ref in pr.dependsOn ?? [] {
      if let i = edges.firstIndex(where: { ref.same(repo: $0.repo, number: $0.number) }) {
        edges[i].deploy = edges[i].deploy || ref.deploy
        continue
      }
      let session = owned.first { ref.same(repo: $0.pr.repo, number: $0.pr.number) }?.id
      edges.append(Dependency(via: .body, repo: ref.repo, number: ref.number, deploy: ref.deploy, session: session))
    }
    return edges.map { withState($0, recorded: recorded) }
  }

  /// The edge with its PR's state as this poller last read it. A deploy edge
  /// whose PR merged is deployed once the deploy comment shows both prod
  /// regions deployed.
  ///
  /// The poller's reads and comment bodies are in memory, so they are empty
  /// after sbd restarts. An edge whose PR this poller has not read keeps the
  /// state that the session recorded. A merged deploy edge whose comment
  /// bodies have not loaded keeps the recorded `deployed`. Otherwise a failed
  /// read after a restart would overwrite the recorded state, and the next
  /// good read would not tell the session that the edge resolved.
  private func withState(_ edge: Dependency, recorded: [Dependency]) -> Dependency {
    var d = edge
    let before = recorded.first { $0.same(repo: edge.repo, number: edge.number) }
    guard let read = lastRead(edge) else {
      if let before {
        d.state = before.state
        d.deployed = d.deploy ? before.deployed : nil
      }
      return d
    }
    d.state = read.pr.state
    d.deployed = nil
    if d.deploy, read.pr.state == .merged {
      let comments = keptComments(read.comments)
      if let comment = comments.compactMap({ $0.body.flatMap(DeployComment.parse) }).last {
        d.deployed = comment.deployedToProd
      } else if let before, before.state == .merged, comments.contains(where: { $0.body == nil }) {
        d.deployed = before.deployed ?? false
      } else {
        d.deployed = false
      }
    }
    return d
  }

  private func lastRead(_ edge: Dependency) -> (pr: PullRequest, comments: [PRComment], polled: Int64)? {
    prs.values.first { edge.same(repo: $0.pr.repo, number: $0.pr.number) }
  }

  static func resolvedLine(_ d: Dependency, _ pr: PullRequest) -> String {
    let label = d.label(from: pr.repo)
    if d.deploy { return "\(label) deployed to prod, so #\(pr.number) no longer waits on it." }
    if d.via == .stack { return "\(label) merged; retarget and rebase #\(pr.number)." }
    return "\(label) merged, so #\(pr.number) no longer waits on it."
  }
}
