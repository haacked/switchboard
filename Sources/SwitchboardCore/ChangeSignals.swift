import Foundation

/// Kinds of change to a PR. A source of PR changes reports some of them, and a PR's open waits need the poller to
/// see some of them.
public struct ChangeSignals: OptionSet, Hashable, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let head = ChangeSignals(rawValue: 1 << 0)
  public static let checkSuites = ChangeSignals(rawValue: 1 << 1)
  public static let checkRuns = ChangeSignals(rawValue: 1 << 2)
  public static let commitStatuses = ChangeSignals(rawValue: 1 << 3)
  public static let reviews = ChangeSignals(rawValue: 1 << 4)
  public static let state = ChangeSignals(rawValue: 1 << 5)
  public static let conflict = ChangeSignals(rawValue: 1 << 6)
  public static let comments = ChangeSignals(rawValue: 1 << 7)
  public static let mergeQueue = ChangeSignals(rawValue: 1 << 8)
  public static let labels = ChangeSignals(rawValue: 1 << 9)

  public static let all: ChangeSignals = [
    .head, .checkSuites, .checkRuns, .commitStatuses, .reviews, .state, .conflict, .comments, .mergeQueue, .labels,
  ]

  /// What a PR in Trunk's merge queue needs. Trunk reports the queue in a comment on the PR. Trunk's queue is not
  /// GitHub's merge queue, so the PR doesn't need `mergeQueue`.
  public static let trunkQueue: ChangeSignals = [.comments, .state]
}

extension Wait.Kind {
  /// The changes that a wait of this kind needs the poller to see. Every kind needs at least one. A kind that doesn't
  /// name a PR needs every change.
  public var needs: ChangeSignals {
    switch self {
    case .ci: [.head, .checkSuites, .checkRuns, .commitStatuses]
    case .review, .botReview, .approval: [.reviews]
    case .merge: [.state]
    case .queue: [.comments, .mergeQueue, .state]
    case .deploy: [.comments, .state]
    case .session, .date, .manual, .reply: .all
    }
  }

  /// The kinds of signal that report the change a wait of this kind waits for, or nil for a kind whose change no
  /// signal reports. No source reports the comments that a `queue` or `deploy` wait reads.
  public var signalKinds: Set<PRSignal.Kind>? {
    switch self {
    case .ci: [.checks, .head]
    case .review, .botReview, .approval: [.review]
    case .merge: [.state]
    case .queue, .deploy, .session, .date, .manual, .reply: nil
    }
  }
}

extension Wait {
  /// The changes that the wait needs the poller to see on its PR. A wait that doesn't need its PR read at the
  /// pending rate needs none. Otherwise a PR with the wait polls at the pending rate.
  public func needs(for pr: SwitchboardCore.PullRequest?) -> ChangeSignals {
    readsPRWhilePending(pr) ? kind.needs : []
  }
}
