import Foundation
import SwitchboardCore

/// Turns what the providers report into reads by the GitHub poller and into the coverage that the poll rates read.
/// It belongs to `GitHubPoller` and runs on the poller's queue. A signal only asks for a read, so every change still
/// reaches the waits through the poller's read.
final class PRChangeHub {
  let providers: [any PRChangeProvider]
  /// The providers in the order sbd prefers them: the one that reports more kinds of change first, and on a tie the
  /// one that comes first in `providers`.
  private let byPreference: [any PRChangeProvider]
  let queue: DispatchQueue
  weak var reader: (any PRReader)?
  /// In shadow mode a signal or a coverage change never asks for a read and never changes a poll rate. The hub only
  /// counts what the providers report and measures it against the poller's reads.
  let shadow: Bool
  /// The clock in ms. Tests replace it.
  var now: () -> Int64 = nowMs

  /// The wait before a signal's read, so that a burst of signals shares one read.
  static let delayMs: Int64 = 2_000
  /// The wait before a `head` signal's read, so that GitHub can create the new head's check suites.
  static let headDelayMs: Int64 = 5_000
  /// The least time between two signal-caused reads of one PR, unless a check failed.
  static let spacingMs: Int64 = 15_000
  /// How long the hub ignores a signal id that it saw.
  static let dedupeMs: Int64 = 600_000
  /// GitHub can lose events in a short window after a subscription is created. A PR's catch-up read comes this long
  /// after its provider's `since`.
  static let catchUpMs: Int64 = 5_000
  /// How long a provider stays live for a PR before the PR counts as covered, so its poll rates read the provider's
  /// signals.
  static let liveMs: Int64 = 60_000

  /// A PR that the poller read and that a session, wait, or merge trigger names.
  struct KnownPR: Equatable {
    var ref: PRRef
    var headSha: String
    /// When the poller last read the PR, in ms.
    var polled: Int64
    /// The fields of the read that shadow mode compares between reads.
    var snapshot: ShadowTally.Snapshot? = nil
  }

  /// The PRs of the last poll, by node id.
  private var known: [String: KnownPR] = [:]
  private var ids: [PRRef: String] = [:]
  /// The signal ids of the last `dedupeMs`, by provider and id, with when each arrived.
  private var seen: [String: Int64] = [:]
  /// The time of each PR's last signal-caused read, by node id. It is the time the hub asked for until the poller
  /// stores a read that serves the PR's signals, and then the time of that read. A time after now is a read that
  /// hasn't run.
  private var signalReads: [String: Int64] = [:]
  /// The time from which a stored read serves each PR's signals, by node id, until the poller stores such a read. A
  /// `head` signal needs a read from the end of its delay. Any other signal needs a read from after its arrival.
  private var neededReads: [String: Int64] = [:]

  /// A provider's last report for one scope. `since` is nil when the scope went down. `order` is the report's
  /// place among all reports, so the latest report for a PR wins over an earlier one for a wider scope.
  private struct Coverage {
    var since: Int64?
    var gap: Bool
    var order: Int
  }

  /// Each provider's coverage, by provider id and scope.
  private var coverage: [String: [CoverageChange.Scope: Coverage]] = [:]
  private var reports = 0

  private struct Counts {
    /// The availability that the provider last reported through its sink.
    var reported: Availability?
    var changedAt: Int64?
    var wanted = 0
    var signals = 0
    var reads = 0
    var lastSignalAt: Int64?
  }

  private var counts: [String: Counts] = [:]
  /// What shadow mode measured for each provider, by provider id.
  private var tallies: [String: ShadowTally] = [:]

  /// A read that the next poll's tally takes, with the PR's read before it and the time that read's poll started.
  private struct HeldRead {
    var id: String
    var ref: PRRef
    var snapshot: ShadowTally.Snapshot
    var previous: (snapshot: ShadowTally.Snapshot, polled: Int64)?
  }

  private var heldReads: [HeldRead] = []
  /// When the poll that made `heldReads` ended, in ms.
  private var heldAt: Int64 = 0
  private var pendingReads = 0
  private var reviewOnlyReads = 0

  init(providers: [any PRChangeProvider], queue: DispatchQueue, shadow: Bool = false) {
    self.shadow = shadow
    self.providers = providers
    byPreference = providers.enumerated().sorted { a, b in
      let (ka, kb) = (a.element.signals.rawValue.nonzeroBitCount, b.element.signals.rawValue.nonzeroBitCount)
      return ka != kb ? ka > kb : a.offset < b.offset
    }.map(\.element)
    self.queue = queue
  }

  /// Starts each provider with a sink of its own, which takes what the provider reports to the poller's queue.
  func start() {
    for p in providers { p.start(sink: Sink(provider: p.id, hub: self)) }
  }

  /// A provider's sink. It names the provider, so a provider can't report for another one.
  private final class Sink: PRChangeSink {
    let provider: String
    weak var hub: PRChangeHub?

    init(provider: String, hub: PRChangeHub) {
      self.provider = provider
      self.hub = hub
    }

    /// Stamps the signal's arrival here, because the poller's queue can hold it until a poll ends.
    func signal(_ s: PRSignal) {
      guard let hub else { return }
      let at = hub.now()
      hub.onQueue { $0.receive(s, from: self.provider, at: at) }
    }
    func coverage(_ change: CoverageChange) { hub?.onQueue { $0.receive(change, from: self.provider) } }
    func availability(_ provider: String, _ a: Availability) {
      hub?.onQueue { $0.receive(a, from: self.provider) }
    }
  }

  private func onQueue(_ work: @escaping (PRChangeHub) -> Void) {
    queue.async { [weak self] in self.map(work) }
  }

  // MARK: The poller's side

  /// Takes the PRs that the poll read and the open PRs ranked by `PRInterest.ranked`. It gives each provider the
  /// ranked list without the PRs that a preferred provider is live for, and it asks again for each catch-up read
  /// that hasn't happened.
  func cycleEnded(known: [String: KnownPR], interest: [PRRef]) {
    dispatchPrecondition(condition: .onQueue(queue))
    if shadow {
      tallyLastPoll()
      holdForTally(known)
    }
    self.known = known
    seen = seen.filter { now() - $0.value < Self.dedupeMs }
    ids = Dictionary(known.map { ($0.value.ref, $0.key) }) { a, _ in a }
    if !shadow { settleNeededReads() }
    signalReads = signalReads.filter { known[$0.key] != nil }
    for (provider, scopes) in coverage {
      coverage[provider] = scopes.filter { scope, _ in
        guard case .pr(let ref) = scope else { return true }
        return ids[ref] != nil
      }
    }
    for p in providers {
      let wanted = interest.filter { preferred(over: p.id, for: $0) == nil }
      counts[p.id, default: Counts()].wanted = wanted.count
      p.setInterest(wanted)
    }
    if !shadow { requestCatchUps(fromPoll: true) }
  }

  /// Adds the reads of PRs that polled at the pending rate in one poll, and how many of them only awaited a review.
  func countPendingReads(total: Int, reviewOnly: Int) {
    dispatchPrecondition(condition: .onQueue(queue))
    pendingReads += total
    reviewOnlyReads += reviewOnly
  }

  /// Keeps the PRs that this poll read, with the time the poll ended, for the next poll's tally. A signal that a
  /// provider sends during a poll waits on the poller's queue until the poll ends, so the tally runs once those
  /// signals are in. Must run before `known` takes the new reads.
  private func holdForTally(_ reads: [String: KnownPR]) {
    heldAt = now()
    heldReads = reads.compactMap { id, pr in
      let old = known[id]
      guard let snapshot = pr.snapshot, old.map({ pr.polled > $0.polled }) ?? true else { return nil }
      let previous = old.flatMap { o in o.snapshot.map { (snapshot: $0, polled: o.polled) } }
      return HeldRead(id: id, ref: pr.ref, snapshot: snapshot, previous: previous)
    }.sorted { $0.id < $1.id }
  }

  /// Gives each provider's tally the reads that the last poll held, with each PR's read before them, and logs each
  /// miss. A read shows its change at the time its poll ended. The read before it counts from when its poll started,
  /// so a source that went live during that poll can't count a miss.
  private func tallyLastPoll() {
    let now = now()
    for p in providers {
      var t = tallies.removeValue(forKey: p.id) ?? ShadowTally()
      for read in heldReads {
        let missed = t.read(
          read.id, previous: read.previous, now: read.snapshot, polled: heldAt,
          liveSince: live(p.id, for: read.ref)?.since)
        if !missed.isEmpty {
          logLine(
            "github: \(p.id) sent no signal for \(read.ref.repo)#\(read.ref.number) before a poll showed its "
              + missed.joined(separator: ", ") + " change")
        }
      }
      t.prune(now: now)
      tallies[p.id] = t
    }
    heldReads = []
  }

  /// The signals of the provider that covers each covered PR, by node id. The poll rates read it.
  func coveredSignals() -> [String: ChangeSignals] {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !shadow else { return [:] }
    return known.compactMapValues { coveringProvider(of: $0)?.signals }
  }

  /// One entry for each provider, for `sb sources`.
  func report() -> PRSources {
    dispatchPrecondition(condition: .onQueue(queue))
    let covering = known.values.compactMap { coveringProvider(of: $0)?.id }
    return PRSources(
      providers: providers.map { p in
        let c = counts[p.id] ?? Counts()
        let status = p.status
        let t = tallies[p.id] ?? ShadowTally()
        var source = PRSources.Source(
          id: p.id, state: "live", changedAt: c.changedAt, wanted: c.wanted,
          covered: covering.filter { $0 == p.id }.count, signals: c.signals, reads: c.reads,
          lastSignalAt: c.lastSignalAt, counts: status.counts, shadow: shadow, matched: t.matched,
          unmatched: t.unmatched, misses: t.misses, medianLeadMs: t.medianLeadMs)
        switch status.availability {
        case .available: break
        case .unavailable(let reason, let retryAt):
          (source.state, source.reason, source.retryAt) = ("unavailable", reason, retryAt)
        case .off: source.state = "off"
        }
        return source
      }, pendingReads: pendingReads, reviewOnlyReads: reviewOnlyReads)
  }

  // MARK: The providers' side

  private func receive(_ s: PRSignal, from provider: String, at arrived: Int64) {
    let now = now()
    counts[provider, default: Counts()].signals += 1
    counts[provider]?.lastSignalAt = now
    let key = "\(provider) \(s.id)"
    if let at = seen[key], now - at < Self.dedupeMs { return }
    seen[key] = now
    for id in targets(of: s.target).sorted() {
      if shadow {
        tallies[provider, default: ShadowTally()].signal(id, kind: s.kind, at: arrived)
      } else {
        requestSignalRead(id, s, provider: provider, now: now)
      }
    }
  }

  /// The node ids of the PRs that the poller tracks and that the target names.
  private func targets(of target: PRSignal.Target) -> [String] {
    switch target {
    case .pr(let ref): ids[ref].map { [$0] } ?? []
    case .commit(let repo, let sha): known.filter { $0.value.ref.repo == repo && $0.value.headSha == sha }.map(\.key)
    }
  }

  /// Asks for a read of the PR after the signal's delay, and no sooner than `spacingMs` after the PR's last
  /// signal-caused read unless a check failed. A signal that comes while that read hasn't run shares it, unless a
  /// failed check's delay ends sooner, which moves the read to that time. A delay only moves a read later.
  private func requestSignalRead(_ id: String, _ s: PRSignal, provider: String, now: Int64) {
    var at = now + (s.kind == .head ? Self.headDelayMs : Self.delayMs)
    neededReads[id] = max(neededReads[id] ?? 0, s.kind == .head ? at : now + 1)
    if let last = signalReads[id], last > now {
      // A `head` signal whose delay ends after the pending read needs a read of its own, which `settleNeededReads`
      // asks for once the pending read has run.
      if s.kind == .head && at > last { counts[provider, default: Counts()].reads += 1 }
      guard s.failed, at < last else { return }
    } else if let last = signalReads[id], !s.failed {
      at = max(at, last + Self.spacingMs)
    }
    signalReads[id] = at
    counts[provider, default: Counts()].reads += 1
    reader?.requestRead([id], after: at - now, trigger: .event)
  }

  /// Ends each PR's need for a read once the poller stores a read from the needed time, and measures the spacing from
  /// that read. `ReadRequests` keeps one time for each PR, so a read that another trigger asked for can take the place
  /// of the hub's read and run too early. While the need remains, the hub asks again: at its pending read's time, or
  /// `spacingMs` after that time once it has passed. A time that has passed waits for the next poll, so a poll that
  /// fails doesn't wake another at once.
  private func settleNeededReads() {
    let now = now()
    for (id, needed) in neededReads.sorted(by: { $0.key < $1.key }) {
      guard let polled = known[id]?.polled else {
        neededReads[id] = nil
        continue
      }
      if polled >= needed {
        // A timed read that the hub asked for and that hasn't run would come sooner than the spacing allows.
        if let last = signalReads[id], last > now { reader?.cancelRead(id, trigger: .event) }
        neededReads[id] = nil
        signalReads[id] = polled
        continue
      }
      let last = signalReads[id] ?? 0
      let at = last > now ? last : max(needed, last + Self.spacingMs)
      signalReads[id] = at
      if at > now {
        reader?.requestRead([id], after: at - now, trigger: .event)
      } else {
        reader?.readAtNextPoll([id], trigger: .event)
      }
    }
  }

  private func receive(_ change: CoverageChange, from provider: String) {
    reports += 1
    switch change {
    case .live(let scope, let since, let gap):
      set(scope, Coverage(since: since, gap: gap, order: reports), for: provider)
      if gap && !shadow {
        counts[provider, default: Counts()].reads += requestCatchUps(fromPoll: false, in: scope, of: provider)
      }
    case .down(let scope, _):
      set(scope, Coverage(since: nil, gap: false, order: reports), for: provider)
    }
  }

  /// Records the provider's report for the scope. It replaces the provider's reports for the scopes inside it.
  private func set(_ scope: CoverageChange.Scope, _ report: Coverage, for provider: String) {
    var scopes = (coverage[provider] ?? [:]).filter { !scope.contains($0.key) }
    scopes[scope] = report
    coverage[provider] = scopes
  }

  private func receive(_ a: Availability, from provider: String) {
    guard counts[provider]?.reported != a else { return }
    counts[provider, default: Counts()].reported = a
    counts[provider]?.changedAt = now()
    switch a {
    case .available: logLine("github: \(provider) is live")
    case .unavailable(let reason, _): logLine("github: \(provider) is unavailable: \(reason)")
    case .off: logLine("github: \(provider) is off")
    }
    // A provider that can't report covers nothing until it reports `live` again.
    if a != .available { coverage[provider] = nil }
  }

  // MARK: Coverage

  /// The provider's latest report that applies to the PR, when it says the provider is live.
  private func live(_ provider: String, for ref: PRRef) -> Coverage? {
    let report = coverage[provider]?.lazy.filter { $0.key.contains(ref) }.max { $0.value.order < $1.value.order }?.value
    return report?.since == nil ? nil : report
  }

  /// A provider that sbd prefers to `provider` and that is live for the PR.
  private func preferred(over provider: String, for ref: PRRef) -> (any PRChangeProvider)? {
    byPreference.prefix { $0.id != provider }.first { live($0.id, for: ref) != nil }
  }

  /// The provider that covers the PR: it has been live for the PR for `liveMs`, and the poller stored a read from
  /// `catchUpMs` after it went live. The preferred provider wins when two cover it.
  private func coveringProvider(of pr: KnownPR) -> (any PRChangeProvider)? {
    let now = now()
    return byPreference.first { p in
      guard let since = live(p.id, for: pr.ref)?.since else { return false }
      return now >= since + Self.liveMs && pr.polled >= since + Self.catchUpMs
    }
  }

  /// Asks for a catch-up read of each tracked PR that a provider went live for with a gap and that the poller hasn't
  /// read since `catchUpMs` after. A read at a time that has passed waits for the next poll when the poll asks, so a
  /// poll that fails doesn't wake another at once. Returns how many reads it asked for.
  @discardableResult
  private func requestCatchUps(fromPoll: Bool, in scope: CoverageChange.Scope = .everything, of provider: String? = nil)
    -> Int
  {
    let now = now()
    var requested = 0
    for (id, pr) in known.sorted(by: { $0.key < $1.key }) where scope.contains(pr.ref) {
      let due = providers.filter { provider == nil || $0.id == provider }.compactMap { p -> Int64? in
        guard let c = live(p.id, for: pr.ref), c.gap, let since = c.since else { return nil }
        return since + Self.catchUpMs
      }.max()
      guard let due, pr.polled < due else { continue }
      requested += 1
      if fromPoll && due <= now {
        reader?.readAtNextPoll([id], trigger: .catchup)
      } else {
        reader?.requestRead([id], after: max(0, due - now), trigger: .catchup)
      }
    }
    return requested
  }
}
