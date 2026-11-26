import Foundation
import SwitchboardCore

/// What the poller tells the hub at the end of each poll, and the coverage that its poll rates read.
extension GitHubPoller {
  /// The poll rates of each PR, with the signals of the provider that covers it.
  func pollPolicy() -> PollPolicy {
    settings.pollPolicy(covered: hub.coveredSignals())
  }

  /// Gives the hub the PRs that the poller read and the open PRs ranked by what sbd wants reported. Without a
  /// provider it does nothing. It runs after the poll drops the PRs that nothing names.
  func feedHub(_ sessions: [Watched], _ interest: Interest) {
    guard !hub.providers.isEmpty else { return }
    let waited = waitedOn(interest)
    let queued = queuedPRs()
    let live = Set(sessions.filter(\.facts.live).compactMap { tracked[$0.id]?.prId })
    var known: [String: PRChangeHub.KnownPR] = [:]
    var candidates: [PRInterest] = []
    for (id, read) in prs {
      let ref = PRRef(repo: read.pr.repo, number: read.pr.number)
      known[id] = PRChangeHub.KnownPR(
        ref: ref, headSha: read.pr.headSha, polled: read.polled,
        snapshot: hub.shadow ? ShadowTally.Snapshot(read.pr) : nil)
      candidates.append(
        PRInterest(
          ref: ref, open: read.pr.state == .open, waitedAt: waited.created[id],
          pending: read.pr.pollsAtPendingRate(needed: !waited.needs(of: id, queued: queued).isEmpty),
          live: live.contains(id)))
    }
    hub.cycleEnded(known: known, interest: PRInterest.ranked(candidates))
  }
}

extension GitHubPoller: PRReader {}
