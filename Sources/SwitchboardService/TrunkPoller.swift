import Foundation
import SwitchboardCore

/// Reads Trunk's merge queue with `trunk merge status <N>`, for the PRs that
/// the GitHub poll shows in the queue. trunk reads the repository from the
/// folder it runs in, so each PR runs in a checkout of its repository. It
/// runs on the GitHub poller's queue.
final class TrunkPoller {
  let settings: TrunkSettings
  /// How often one PR reads trunk.
  let intervalMs: Int64
  /// The last result for each PR, by node id, and when its read started.
  private var reads: [String: (result: TrunkTimeline.Result, at: Int64)] = [:]
  /// Why the last read couldn't use trunk, such as a missing login. A read
  /// that trunk answers clears it.
  private(set) var problem: String?

  static let notLoggedIn =
    "trunk is not signed in, so the merge queue state comes from Trunk's comments. Run `trunk login`."

  /// A PR that the queue may hold, and a checkout of its repository.
  struct Candidate {
    var prId: String
    var number: Int
    var cwd: String
    /// When the comment that gives the comments' queue state last changed.
    var changedAt: Int64?
  }

  init(settings: TrunkSettings, intervalMs: Int64) {
    self.settings = settings
    self.intervalMs = intervalMs
  }

  func result(_ prId: String) -> TrunkTimeline.Result? { reads[prId]?.result }

  /// Reads each candidate that is due, or every candidate with `all`, and
  /// forgets the PRs that are no longer candidates. A candidate whose comments
  /// changed after its last read is due at once, because that read can
  /// describe an earlier run of the PR. Once trunk reports no login, the other
  /// due PRs get the same answer without a run. Returns how many times trunk
  /// ran.
  func poll(_ candidates: [Candidate], all: Bool, now: Int64) -> Int {
    let ids = Set(candidates.map(\.prId))
    reads = reads.filter { ids.contains($0.key) }
    let due = candidates.filter { c in
      let last = reads[c.prId]?.at
      return all || GitHub.elapsed(since: last, intervalMs, now: now) || (c.changedAt ?? 0) > (last ?? 0)
    }
    guard !due.isEmpty else { return 0 }
    guard let trunk = settings.executable() else {
      report("can't find trunk at \(settings.path)")
      return 0
    }
    var runs = 0
    var loggedOut = false
    for c in due {
      if loggedOut {
        reads[c.prId] = (.notLoggedIn, now)
        continue
      }
      guard let result = read(trunk, c, now: now) else { continue }
      runs += 1
      reads[c.prId] = (result, now)
      loggedOut = result == .notLoggedIn
    }
    return runs
  }

  /// Runs trunk for one PR. nil when trunk didn't start.
  private func read(_ trunk: String, _ c: Candidate, now: Int64) -> TrunkTimeline.Result? {
    let r: CommandResult
    do {
      r = try runCommand(trunk, ["merge", "status", "\(c.number)"], timeout: settings.timeoutSeconds, cwd: c.cwd)
    } catch {
      report("trunk merge status \(c.number) failed: \(error)")
      return nil
    }
    let result = TrunkTimeline.parse(r.stdout + r.stderr, now: now)
    switch result {
    case .found, .notFound:
      problem = nil
    case .notLoggedIn:
      report(TrunkPoller.notLoggedIn)
    case .unrecognized(let text):
      logLine("trunk: merge status \(c.number) in \(c.cwd) printed \(oneLine(text, max: 200))")
    }
    return result
  }

  private func report(_ text: String) {
    if text != problem { logLine("trunk: \(text)") }
    problem = text
  }
}
