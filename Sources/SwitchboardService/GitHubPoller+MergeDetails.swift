import Foundation
import SwitchboardCore

/// The size, review threads, and description of each session's PR at a
/// merge decision, for its merge card.
extension GitHubPoller {
  /// Reads the details of each session's open PR that is at a merge
  /// decision, when no read holds them at the PR's head or the status query
  /// read the PR again since. A failed chunk keeps its last reads. Returns
  /// the first failure.
  func readMergeDetails(_ sessions: [Watched], now: Int64, stats: inout Stats) -> String? {
    var due: Set<String> = []
    for s in sessions {
      guard let id = tracked[s.id]?.prId, !due.contains(id), let read = prs[id], let pr = shown(id, last: s.facts.pr)
      else { continue }
      if let cached = mergeDetails[id], cached.head == pr.headSha, cached.read >= read.polled { continue }
      var facts = s.facts
      facts.pr = pr
      if Attention.atMergeDecision(facts) { due.insert(id) }
    }
    var failure: String?
    for chunk in GitHub.chunks(due.sorted()) {
      do {
        let response = try request(GitHub.mergeDetailsQuery, idsVariable(chunk), stats: &stats)
        let nodes = response["data"]?["nodes"]?.array ?? []
        for (i, id) in chunk.enumerated() {
          guard i < nodes.count, let (head, details) = GitHub.parseMergeDetails(nodes[i]) else {
            failure = failure ?? "GitHub failed to read the merge details of \(id): \(GitHub.message(response))"
            continue
          }
          mergeDetails[id] = (head, now, details)
        }
      } catch {
        failure = failure ?? "merge details: \(error)"
      }
    }
    return failure
  }

  /// Sets each PR's merge details from the read at its head. A status read
  /// rebuilds the PR without them.
  func applyMergeDetails() {
    for (id, read) in prs {
      guard let cached = mergeDetails[id], cached.head == read.pr.headSha else { continue }
      prs[id]!.pr.mergeDetails = cached.details
    }
  }

  /// Keeps only the reads of the PRs in `prs` at their current head.
  func pruneMergeDetails() {
    mergeDetails = mergeDetails.filter { prs[$0.key]?.pr.headSha == $0.value.head }
  }
}
