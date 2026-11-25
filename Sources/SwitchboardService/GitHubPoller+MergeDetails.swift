import Foundation
import SwitchboardCore

/// The size, review threads, and description of each session's PR at a
/// merge decision, for its merge card, and of each PR In review, for its
/// review nudge.
extension GitHubPoller {
  /// Reads the details of each session's open PR that is at a merge
  /// decision, when no read holds them at the PR's head or the status query
  /// read the PR again since. Reads a PR In review once per head commit. A
  /// read asks for thread comments only for a PR at a merge decision that
  /// has or may have open threads, and reads such a PR again with them
  /// when a read without them finds an open thread. A failed chunk keeps
  /// its last reads. Returns the first failure.
  func readMergeDetails(_ sessions: [Watched], now: Int64, stats: inout Stats) -> String? {
    var wantsThreadComments: [String: Bool] = [:]
    var decisions: Set<String> = []
    for s in sessions {
      guard let id = tracked[s.id]?.prId, !GitLab.isMR(id), wantsThreadComments[id] == nil, let read = prs[id],
        let pr = shown(id, last: s.facts.pr)
      else { continue }
      let cached = mergeDetails[id].flatMap { $0.head == pr.headSha ? $0 : nil }
      var facts = s.facts
      facts.pr = pr
      if Attention.atMergeDecision(facts) {
        decisions.insert(id)
        if (cached?.read ?? .min) < read.polled {
          wantsThreadComments[id] = cached.map { $0.details.mayHaveOpenThreads } ?? true
        }
      } else if cached == nil, BoardColumn.wantsNudgeDetails(pr) {
        wantsThreadComments[id] = false
      }
    }
    var failure: String?
    readDetails(
      wantsThreadComments.filter(\.value).map(\.key), threads: true, now: now, stats: &stats, failure: &failure)
    let read = readDetails(
      wantsThreadComments.filter { !$0.value }.map(\.key), threads: false, now: now, stats: &stats, failure: &failure)
    let again = read.filter { id in
      guard decisions.contains(id), let details = mergeDetails[id]?.details else { return false }
      return details.openThreads > 0 && details.threadDetails == nil
    }
    readDetails(Array(again), threads: true, now: now, stats: &stats, failure: &failure)
    return failure
  }

  /// Reads the details of `ids` and returns the ids it read. Sets `failure`
  /// to the first failure when it has none.
  @discardableResult
  private func readDetails(
    _ ids: [String], threads: Bool, now: Int64, stats: inout Stats, failure: inout String?
  ) -> Set<String> {
    var read: Set<String> = []
    for chunk in GitHub.chunks(ids.sorted()) {
      do {
        let response = try request(
          GitHub.mergeDetailsQuery, idsVariable(chunk, with: ["threads": .bool(threads)]), stats: &stats)
        let nodes = response["data"]?["nodes"]?.array ?? []
        for (i, id) in chunk.enumerated() {
          guard i < nodes.count, let (head, details) = GitHub.parseMergeDetails(nodes[i]) else {
            failure = failure ?? "GitHub failed to read the merge details of \(id): \(GitHub.message(response))"
            continue
          }
          mergeDetails[id] = (head, now, details)
          read.insert(id)
        }
      } catch {
        failure = failure ?? "merge details: \(error)"
      }
    }
    return read
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
