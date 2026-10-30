import Foundation

public enum PRState: String, Codable, Sendable {
  case open = "OPEN"
  case merged = "MERGED"
  case closed = "CLOSED"
}

public enum Mergeable: String, Codable, Sendable {
  case mergeable = "MERGEABLE"
  case conflicting = "CONFLICTING"
  /// GitHub hasn't computed the mergeability yet.
  case unknown = "UNKNOWN"
}

public enum ReviewDecision: String, Codable, Sendable {
  case approved = "APPROVED"
  case changesRequested = "CHANGES_REQUESTED"
  case reviewRequired = "REVIEW_REQUIRED"
}

/// The words of `git pr` for a PR's state and review.
public enum PRStatus: String, Codable, Sendable {
  case merged = "Merged"
  case closed = "Closed"
  case draft = "Draft"
  case approved = "Approved"
  case changesRequested = "Changes requested"
  case reviewRequired = "Review required"
  case notApproved = "Not approved"
}

/// A review of a PR, or a reviewer's last verdict.
public struct Review: Codable, Equatable, Sendable {
  public var author: String
  /// APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED, or PENDING.
  public var state: String
  public var submittedAt: String?
  /// The commit that the review was made on. Only a verdict carries it.
  public var commit: String?
  /// True when a GitHub App wrote the review. nil for a person.
  public var bot: Bool?

  public init(
    author: String, state: String, submittedAt: String? = nil, commit: String? = nil, bot: Bool? = nil
  ) {
    self.author = author
    self.state = state
    self.submittedAt = submittedAt
    self.commit = commit
    self.bot = bot
  }
}

/// A comment on a PR. A status response carries no body. The poller reads
/// the bodies of the comments that `GitHub.bodyAuthors` wrote.
public struct PRComment: Codable, Equatable, Sendable {
  public var id: String
  /// The login, which ends in [bot] for a GitHub App, as in GitHub's REST API.
  public var author: String
  public var createdAt: String
  public var editedAt: String?
  /// GitHub's includesCreatedEdit: the comment changed after it was posted.
  /// Trunk edits its status comment in place.
  public var edited: Bool
  public var body: String?

  public init(
    id: String, author: String, createdAt: String, editedAt: String? = nil, edited: Bool = false, body: String? = nil
  ) {
    self.id = id
    self.author = author
    self.createdAt = createdAt
    self.editedAt = editedAt
    self.edited = edited
    self.body = body
  }
}

/// A PR as the poller last read it from GitHub.
public struct PullRequest: Codable, Equatable, Sendable {
  /// GitHub's node id.
  public var id: String
  public var number: Int
  public var url: String
  /// owner/name.
  public var repo: String
  public var title: String
  public var state: PRState
  public var draft: Bool
  public var head: String
  public var headSha: String
  public var base: String
  public var defaultBranch: String?
  public var mergeable: Mergeable?
  /// GitHub leaves it nil when the base branch requires no review.
  public var reviewDecision: ReviewDecision?
  /// Each reviewer's last approval or change request.
  public var verdicts: [Review]
  /// The last 20 reviews, oldest first.
  public var reviews: [Review]
  public var labels: [String]
  /// The rollup state of the head commit's checks: SUCCESS, FAILURE, ERROR,
  /// PENDING, or EXPECTED. nil when the commit has no checks.
  public var checks: String?
  /// The number of the merged PR whose head branch is this PR's base, while
  /// nothing landed on the base after the merge. GitHub shows it only while
  /// the base branch exists.
  public var mergedBase: Int?
  public var mergedAt: String?
  public var closedAt: String?
  /// The Trunk queue state that the trunk-io comments show, and nil when no
  /// comment shows one.
  public var queue: TrunkQueueState?

  public init(
    id: String, number: Int, url: String, repo: String, title: String = "", state: PRState = .open,
    draft: Bool = false, head: String = "", headSha: String = "", base: String = "main",
    defaultBranch: String? = "main", mergeable: Mergeable? = .mergeable, reviewDecision: ReviewDecision? = nil,
    verdicts: [Review] = [], reviews: [Review] = [], labels: [String] = [], checks: String? = nil,
    mergedBase: Int? = nil, mergedAt: String? = nil, closedAt: String? = nil, queue: TrunkQueueState? = nil
  ) {
    self.id = id
    self.number = number
    self.url = url
    self.repo = repo
    self.title = title
    self.state = state
    self.draft = draft
    self.head = head
    self.headSha = headSha
    self.base = base
    self.defaultBranch = defaultBranch
    self.mergeable = mergeable
    self.reviewDecision = reviewDecision
    self.verdicts = verdicts
    self.reviews = reviews
    self.labels = labels
    self.checks = checks
    self.mergedBase = mergedBase
    self.mergedAt = mergedAt
    self.closedAt = closedAt
    self.queue = queue
  }

  /// The PR's `git pr` words. The review decision picks them, or the
  /// reviewers' verdicts do when the base branch requires no review.
  public var status: PRStatus {
    switch state {
    case .merged: return .merged
    case .closed: return .closed
    case .open: break
    }
    if draft { return .draft }
    switch reviewDecision {
    case .approved: return .approved
    case .changesRequested: return .changesRequested
    case .reviewRequired: return .reviewRequired
    case nil:
      if !changesRequestedBy.isEmpty { return .changesRequested }
      return approvers.isEmpty ? .notApproved : .approved
    }
  }

  /// Whether the PR is open, not a draft, and approved.
  public var isApproved: Bool { status == .approved }

  public var approvers: [String] { verdicts.filter { $0.state == "APPROVED" }.map(\.author).sorted() }

  /// The reviewers whose last verdict requests changes.
  public var changesRequestedBy: [String] {
    verdicts.filter { $0.state == "CHANGES_REQUESTED" }.map(\.author).sorted()
  }

  /// Whether something about the PR will change soon: its checks run, or
  /// GitHub hasn't computed its mergeability yet. A merged or closed PR is
  /// never pending.
  public var isPending: Bool {
    state == .open && (checks == "PENDING" || checks == "EXPECTED" || mergeable == .unknown)
  }
}

/// What `sb ls` and the GUI show of a session's PR. The app asks for every
/// session each second, so the summary leaves out the reviews and labels.
public struct PRSummary: Codable, Equatable, Sendable {
  public var number: Int
  public var url: String
  public var repo: String
  public var title: String
  public var state: PRState
  public var status: PRStatus
  public var checks: String?
  public var mergeable: Mergeable?
  public var queue: TrunkQueueState?

  public init(_ pr: PullRequest) {
    number = pr.number
    url = pr.url
    repo = pr.repo
    title = pr.title
    state = pr.state
    status = pr.status
    checks = pr.checks
    mergeable = pr.mergeable
    queue = pr.queue
  }

  /// The PR's page, or nil unless `url` is https. Any local process can
  /// record a `pr` event, and the app opens this link when the user clicks it.
  public var link: URL? {
    guard let url = URL(string: url), url.scheme?.lowercased() == "https" else { return nil }
    return url
  }

  /// The PR in one line, such as "#18303 Approved, checks success".
  public var line: String { "#\(number) \(status.rawValue)\(checks.map { ", checks \($0.lowercased())" } ?? "")" }
}
