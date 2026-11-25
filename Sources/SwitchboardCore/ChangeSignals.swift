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

  /// What a PR in Trunk's merge queue needs. Trunk reports the queue in a comment on the PR.
  public static let trunkQueue: ChangeSignals = [.comments, .state]
}

extension Wait.Kind {
  /// The changes that a wait of this kind needs the poller to see. Every kind needs at least one, so a PR with an
  /// open wait polls at the pending rate. A kind that doesn't name a PR needs every change.
  public var needs: ChangeSignals {
    switch self {
    case .ci: [.head, .checkSuites, .checkRuns, .commitStatuses]
    case .review, .botReview, .approval: [.reviews]
    case .merge: [.state]
    case .queue: [.comments, .mergeQueue, .state]
    case .deploy: [.comments, .state]
    case .session, .date, .manual: .all
    }
  }
}
