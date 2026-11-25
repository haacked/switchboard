import Foundation

/// A pull request on a forge, as a source of PR changes names it.
public struct PRRef: Hashable, Sendable {
  /// The forge's host. A GitLab source would use its own host.
  public var forge: String
  /// The repo as owner/name.
  public var repo: String
  public var number: Int

  public init(forge: String = "github.com", repo: String, number: Int) {
    self.forge = forge
    self.repo = repo
    self.number = number
  }
}

/// A report from a source of PR changes that a PR or a commit changed. A signal never changes what sbd knows about
/// the PR. It only asks the poller to read the PR.
public struct PRSignal: Sendable {
  public enum Kind: String, Sendable {
    case head, checks, review, state, conflict, comment, queue, other
  }

  /// What changed: a PR, or a commit that is the head of one or more PRs.
  public enum Target: Hashable, Sendable {
    case pr(PRRef)
    case commit(repo: String, sha: String)
  }

  /// The id of the provider that sent the signal.
  public var provider: String
  /// The provider's id of the event. The hub ignores an id that it saw in the last 10 minutes.
  public var id: String
  public var target: Target
  public var kind: Kind
  /// When the provider says the change happened, in ms.
  public var at: Int64?
  /// Whether a check failed. The hub then reads the PR without waiting for the spacing between reads.
  public var failed: Bool

  public init(
    provider: String, id: String, target: Target, kind: Kind, at: Int64? = nil, failed: Bool = false
  ) {
    self.provider = provider
    self.id = id
    self.target = target
    self.kind = kind
    self.at = at
    self.failed = failed
  }
}

/// What a provider says about its ability to report changes for some PRs.
public enum CoverageChange: Sendable {
  /// Signals flow from `since`, in ms. With `gap`, changes before `since` may be lost, so each PR needs a read. A
  /// provider that replayed everything from its cursor sends `gap: false`.
  case live(Scope, since: Int64, gap: Bool)
  case down(Scope, reason: String)

  /// The PRs that a coverage change is about.
  public enum Scope: Hashable, Sendable {
    case pr(PRRef)
    /// Every PR in each repo, by owner/name.
    case repos(Set<String>)
    case everything

    public func contains(_ pr: PRRef) -> Bool {
      switch self {
      case .pr(let ref): ref == pr
      case .repos(let repos): repos.contains(pr.repo)
      case .everything: true
      }
    }

    /// Whether every PR of `other` is in this scope.
    public func contains(_ other: Scope) -> Bool {
      switch (self, other) {
      case (.everything, _): true
      case (_, .everything): false
      case (_, .pr(let ref)): contains(ref)
      case (.repos(let repos), .repos(let others)): others.isSubset(of: repos)
      case (.pr, .repos): false
      }
    }
  }
}

/// An open PR that the poller reads, with what decides how much sbd wants a source of PR changes to report it.
public struct PRInterest: Equatable, Sendable {
  public var ref: PRRef
  public var open: Bool
  /// When the newest open wait on the PR was set, in ms, or nil when no open wait names the PR.
  public var waitedAt: Int64?
  /// Whether the PR polls at the pending rate.
  public var pending: Bool
  /// Whether a session that shows the PR is live.
  public var live: Bool

  public init(ref: PRRef, open: Bool, waitedAt: Int64?, pending: Bool, live: Bool) {
    self.ref = ref
    self.open = open
    self.waitedAt = waitedAt
    self.pending = pending
    self.live = live
  }

  /// The open PRs, most wanted first: PRs with an open wait, newest wait first, then pending PRs of live sessions,
  /// then the other open PRs. PRs of one rank keep the order of their repo and number.
  public static func ranked(_ prs: [PRInterest]) -> [PRRef] {
    func rank(_ p: PRInterest) -> (Int, Int64) {
      if let at = p.waitedAt { return (0, -at) }
      return (p.pending && p.live ? 1 : 2, 0)
    }
    return prs.filter(\.open).sorted { a, b in
      let (ra, rb) = (rank(a), rank(b))
      if ra != rb { return ra < rb }
      return (a.ref.repo, a.ref.number) < (b.ref.repo, b.ref.number)
    }.map(\.ref)
  }
}

/// What `sb sources` reports: one entry for each source of PR changes that sbd runs.
public struct PRSources: Codable, Equatable, Sendable {
  public struct Source: Codable, Equatable, Sendable {
    public var id: String
    /// `live`, `unavailable`, or `off`.
    public var state: String
    /// Why the source is unavailable, in the provider's words.
    public var reason: String?
    /// When the provider tries again, in ms.
    public var retryAt: Int64?
    /// When the provider last reported a change of its state, in ms.
    public var changedAt: Int64?
    /// The PRs that sbd asked the source to report.
    public var wanted: Int
    /// The PRs that polling leaves to the source.
    public var covered: Int
    /// The signals that the source sent.
    public var signals: Int
    /// The reads that the source's signals and coverage asked for.
    public var reads: Int
    /// When the last signal arrived, in ms.
    public var lastSignalAt: Int64?
    /// The provider's own counts, such as subscriptions and open streams, by name.
    public var counts: [String: Int]

    public init(
      id: String, state: String, reason: String? = nil, retryAt: Int64? = nil, changedAt: Int64? = nil,
      wanted: Int = 0, covered: Int = 0, signals: Int = 0, reads: Int = 0, lastSignalAt: Int64? = nil,
      counts: [String: Int] = [:]
    ) {
      self.id = id
      self.state = state
      self.reason = reason
      self.retryAt = retryAt
      self.changedAt = changedAt
      self.wanted = wanted
      self.covered = covered
      self.signals = signals
      self.reads = reads
      self.lastSignalAt = lastSignalAt
      self.counts = counts
    }
  }

  public var providers: [Source]

  public init(providers: [Source]) { self.providers = providers }

  /// The lines of `sb sources`: one line for each source, or one line that says sbd polls every PR.
  public func lines(now: Int64) -> [String] {
    guard !providers.isEmpty else { return ["no sources of PR changes: sbd polls GitHub for every PR"] }
    return providers.map { s in
      var parts = ["\(s.id): \(s.state)"]
      if let reason = s.reason { parts[0] += " (\(reason))" }
      if let at = s.retryAt { parts.append("retries \(fromNow(at, now: now))") }
      if let at = s.changedAt { parts.append("since \(ago(at, now: now)) ago") }
      parts.append("covers \(s.covered) of \(s.wanted) PRs")
      parts.append("\(s.signals) signals, \(s.reads) reads")
      if let at = s.lastSignalAt { parts.append("last signal \(ago(at, now: now)) ago") }
      parts += s.counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
      return parts.joined(separator: ", ")
    }
  }
}
