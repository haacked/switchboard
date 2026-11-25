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
  }

  /// The PRs of the last poll, by node id.
  private var known: [String: KnownPR] = [:]
  private var ids: [PRRef: String] = [:]
  /// The signal ids of the last `dedupeMs`, by provider and id, with when each arrived.
  private var seen: [String: Int64] = [:]
  /// The time of each PR's last signal-caused read, by node id. A time after now is a read that hasn't run.
  private var signalReads: [String: Int64] = [:]
  /// When the newest signal joined each PR's pending signal-caused read, by node id.
  private var joinedAt: [String: Int64] = [:]
  /// The time of a read that a `head` signal needs after the PR's pending signal-caused read, by node id.
  /// `ReadRequests` keeps one time for each PR, so the hub asks for it at the end of the poll that ran the pending
  /// read.
  private var owedReads: [String: Int64] = [:]

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

  init(providers: [any PRChangeProvider], queue: DispatchQueue) {
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

    func signal(_ s: PRSignal) { hub?.onQueue { $0.receive(s, from: self.provider) } }
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
    self.known = known
    seen = seen.filter { now() - $0.value < Self.dedupeMs }
    ids = Dictionary(known.map { ($0.value.ref, $0.key) }) { a, _ in a }
    // `ReadRequests` keeps the earlier of two times for a PR, so another trigger's read can run in place of the hub's.
    // That read serves every signal that arrived before it.
    for (id, signalled) in joinedAt {
      guard let polled = known[id]?.polled, polled >= signalled else { continue }
      joinedAt[id] = nil
      if let last = signalReads[id], last > polled { signalReads[id] = polled }
    }
    joinedAt = joinedAt.filter { known[$0.key] != nil }
    signalReads = signalReads.filter { known[$0.key] != nil }
    owedReads = owedReads.filter { known[$0.key] != nil }
    requestOwedReads()
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
    requestCatchUps(fromPoll: true)
  }

  /// The signals of the provider that covers each covered PR, by node id. The poll rates read it.
  func coveredSignals() -> [String: ChangeSignals] {
    dispatchPrecondition(condition: .onQueue(queue))
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
        var source = PRSources.Source(
          id: p.id, state: "live", changedAt: c.changedAt, wanted: c.wanted,
          covered: covering.filter { $0 == p.id }.count, signals: c.signals, reads: c.reads,
          lastSignalAt: c.lastSignalAt, counts: status.counts)
        switch status.availability {
        case .available: break
        case .unavailable(let reason, let retryAt):
          (source.state, source.reason, source.retryAt) = ("unavailable", reason, retryAt)
        case .off: source.state = "off"
        }
        return source
      })
  }

  // MARK: The providers' side

  private func receive(_ s: PRSignal, from provider: String) {
    let now = now()
    counts[provider, default: Counts()].signals += 1
    counts[provider]?.lastSignalAt = now
    let key = "\(provider) \(s.id)"
    if let at = seen[key], now - at < Self.dedupeMs { return }
    seen[key] = now
    for id in targets(of: s.target).sorted() { requestSignalRead(id, s, provider: provider, now: now) }
  }

  /// The node ids of the PRs that the poller tracks and that the target names.
  private func targets(of target: PRSignal.Target) -> [String] {
    switch target {
    case .pr(let ref): ids[ref].map { [$0] } ?? []
    case .commit(let repo, let sha): known.filter { $0.value.ref.repo == repo && $0.value.headSha == sha }.map(\.key)
    }
  }

  /// Asks for a read of the PR after the signal's delay, and no sooner than `spacingMs` after the PR's last
  /// signal-caused read unless a check failed. A signal that comes while that read hasn't run shares it, because the
  /// read comes after the signal. Two cases differ. A failed check whose delay ends sooner moves the read to that
  /// time. A `head` signal whose delay ends later is owed a read of its own after the pending one. A delay only
  /// moves a read later.
  private func requestSignalRead(_ id: String, _ s: PRSignal, provider: String, now: Int64) {
    var at = now + (s.kind == .head ? Self.headDelayMs : Self.delayMs)
    joinedAt[id] = now
    if let last = signalReads[id], last > now {
      if s.kind == .head && at > last {
        owedReads[id] = max(owedReads[id] ?? 0, s.failed ? at : max(at, last + Self.spacingMs))
        counts[provider, default: Counts()].reads += 1
      }
      guard s.failed, at < last else { return }
    } else if let last = signalReads[id], !s.failed {
      at = max(at, last + Self.spacingMs)
    }
    signalReads[id] = at
    counts[provider, default: Counts()].reads += 1
    reader?.requestRead([id], after: at - now, trigger: .event)
  }

  /// Asks for each owed read whose PR has no pending signal-caused read. An owed read whose time has passed waits for
  /// the next poll, so a poll that fails doesn't wake another at once.
  private func requestOwedReads() {
    let now = now()
    for (id, at) in owedReads.sorted(by: { $0.key < $1.key }) where (signalReads[id] ?? 0) <= now {
      owedReads[id] = nil
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
      if gap {
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
