import Foundation
import SwitchboardCore

/// What the Trunk poller needs from a GitHub poll.
extension GitHubPoller {
  /// The PR as its sessions and waits see it: the comments' queue state, or
  /// trunk's when trunk read it.
  func shown(_ id: String, last: PullRequest?) -> PullRequest? {
    guard let read = prs[id] else { return nil }
    return GitHub.shown(read.pr, keptComments(read.comments), trunk: trunk.result(id), last: last)
  }

  /// The PRs that the queue holds as the last reads show them. They poll
  /// GitHub on the pending interval.
  func queuedPRs() -> Set<String> {
    Set(prs.keys.filter { shown($0, last: nil)?.queue?.isQueued == true })
  }

  /// Runs trunk for each open PR whose comments show it in the queue, or
  /// whose comment state didn't load, in a checkout of its repository. A
  /// session's folder is such a checkout when its branch is in the PR's
  /// repository. The session whose PR it is comes first. A PR with no such
  /// session keeps the comments' state. Returns how many times trunk ran.
  func readTrunk(_ sessions: [Watched], all: Bool, now: Int64) -> Int {
    var candidates: [TrunkPoller.Candidate] = []
    for (id, read) in prs.sorted(by: { $0.key < $1.key }) {
      let fromComments = GitHub.shown(read.pr, keptComments(read.comments), last: nil)
      guard let state = fromComments.queue, state.isQueued || state == .unknown else { continue }
      let inRepo = sessions.filter { s in
        guard case .branch(let repo, _, _)? = tracked[s.id]?.branch.key else { return false }
        return Dependencies.sameRepo(repo, read.pr.repo) && FileManager.default.fileExists(atPath: s.cwd)
      }
      guard let checkout = inRepo.first(where: { tracked[$0.id]?.prId == id }) ?? inRepo.first else { continue }
      candidates.append(
        TrunkPoller.Candidate(prId: id, number: read.pr.number, cwd: checkout.cwd, changedAt: fromComments.queueAt))
    }
    let runs = trunk.poll(candidates, known: Set(prs.keys), all: all, now: now)
    let problem = trunk.problem
    service.queue.sync { service.trunkProblem = problem }
    return runs
  }
}
