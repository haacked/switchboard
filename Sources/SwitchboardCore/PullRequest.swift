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
public enum PRStatus: String, Codable, Sendable, CaseIterable {
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
  /// The teams, as `org/team`, that the reviewer approved on behalf of. nil
  /// until sbd reads them.
  public var teams: [String]?

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
  /// Whether the poll read `reviewDecision`, so that a nil there means the
  /// base branch requires no review. nil in events that an older sbd
  /// recorded.
  public var reviewDecisionRead: Bool?
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
  /// The commit that the merge made on the base branch. nil until the PR merges.
  public var mergeCommit: String?
  /// The Trunk queue state that the trunk-io comments show, and nil when no
  /// comment shows one.
  public var queue: TrunkQueueState?
  /// When the comment that gives `queue` last changed, in milliseconds since
  /// the epoch. nil when `queue` is nil or `.unknown`.
  public var queueAt: Int64?
  /// Trunk's name for `queue`, such as "Testing" or "Cancelled", and its
  /// description as markdown. Only `trunk merge status` gives them.
  public var queueLabel: String?
  public var queueText: String?
  /// trunk had no login when sbd asked it about this PR, so `queue` comes
  /// from the comments.
  public var trunkLoginNeeded: Bool?
  /// The logins or team slugs whose review GitHub still asks for. A reviewer
  /// leaves the list when they submit a review. nil means the poll did not
  /// read the field, as in events that an older sbd recorded. An empty list
  /// means nobody was asked.
  public var reviewRequests: [String]?
  /// The Depot run of a head commit, as the Depot poller last read it. It can
  /// be an earlier head commit's run.
  public var depot: DepotRun?
  /// The PRs that the body's `Depends on` lines name. The poller keeps these
  /// and not the body. nil in events that an older sbd recorded.
  public var dependsOn: [PRRef]?
  /// Whether the base repository's default branch has a `.trunk` folder,
  /// which a repository that merges through Trunk's queue keeps. nil when the
  /// poll did not read it, as in events that an older sbd recorded.
  public var trunkConfig: Bool?
  /// Whether the base branch merges through GitHub's merge queue. nil when
  /// the poll did not read it.
  public var mergeQueue: Bool?
  /// Whether the PR is in GitHub's merge queue. nil when the poll did not
  /// read it.
  public var inMergeQueue: Bool?
  /// The PR author's login. nil when the poll did not read it.
  public var author: String?
  /// The code owner groups that the changed files need. nil when the base
  /// branch requires no code owner review. Also nil when sbd cannot tell.
  public var codeOwners: CodeOwnerRequirement?
  /// The users and teams that GitHub asked to review as code owners, as
  /// `@login` or `@org/team`. nil when the poll did not read every request.
  public var codeOwnerRequests: [String]?

  public init(
    id: String, number: Int, url: String, repo: String, title: String = "", state: PRState = .open,
    draft: Bool = false, head: String = "", headSha: String = "", base: String = "main",
    defaultBranch: String? = "main", mergeable: Mergeable? = .mergeable, reviewDecision: ReviewDecision? = nil,
    verdicts: [Review] = [], reviews: [Review] = [], labels: [String] = [], checks: String? = nil,
    mergedBase: Int? = nil, mergedAt: String? = nil, closedAt: String? = nil, queue: TrunkQueueState? = nil,
    reviewRequests: [String]? = nil, mergeCommit: String? = nil, depot: DepotRun? = nil, dependsOn: [PRRef]? = nil,
    trunkConfig: Bool? = nil, reviewDecisionRead: Bool? = nil, mergeQueue: Bool? = nil, inMergeQueue: Bool? = nil,
    author: String? = nil, codeOwnerRequests: [String]? = nil
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
    self.reviewRequests = reviewRequests
    self.mergeCommit = mergeCommit
    self.depot = depot
    self.dependsOn = dependsOn
    self.trunkConfig = trunkConfig
    self.reviewDecisionRead = reviewDecisionRead
    self.mergeQueue = mergeQueue
    self.inMergeQueue = inMergeQueue
    self.author = author
    self.codeOwnerRequests = codeOwnerRequests
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

  /// Whether the base branch's rules ask for a review that GitHub does not
  /// count as given: true for REVIEW_REQUIRED and CHANGES_REQUESTED, false
  /// for APPROVED and for a branch that requires no review. nil when the
  /// poll did not read the decision.
  public var needsReview: Bool? {
    switch reviewDecision {
    case .reviewRequired, .changesRequested: true
    case .approved: false
    case nil: reviewDecisionRead == true ? false : nil
    }
  }

  /// Whether the head commit's checks ended in failure or error.
  public var checksFailed: Bool { checks == "FAILURE" || checks == "ERROR" }

  /// Whether the PR is open, not a draft, and approved.
  public var isApproved: Bool { status == .approved }

  /// Open and not a draft.
  public var ready: Bool { state == .open && !draft }

  /// Whether review lets the PR merge: nobody's last verdict requests
  /// changes, GitHub needs no review, and GitHub approved the PR or no review
  /// request is open. GitHub's approval already counts the required reviews,
  /// so other open requests don't hold an approved PR. A decision that the
  /// poll did not read never satisfies it.
  public var reviewSatisfied: Bool {
    guard changesRequestedBy.isEmpty, needsReview == false else { return false }
    return reviewDecision == .approved || (reviewRequests?.isEmpty ?? true)
  }

  /// When the newest approval was submitted.
  public var approvedAt: String? {
    verdicts.filter { $0.state == "APPROVED" }.compactMap(\.submittedAt).max()
  }

  public var approvers: [String] { verdicts.filter { $0.state == "APPROVED" }.map(\.author).sorted() }

  /// The reviewers whose last verdict requests changes.
  public var changesRequestedBy: [String] {
    verdicts.filter { $0.state == "CHANGES_REQUESTED" }.map(\.author).sorted()
  }

  /// Whether something about the PR will change soon: its checks run, or
  /// GitHub hasn't computed its mergeability yet. A merged or closed PR is
  /// never pending.
  public var isPending: Bool {
    state == .open && (checksRunning || mergeable == .unknown)
  }

  /// Whether the head commit's checks have not finished.
  public var checksRunning: Bool { checks == "PENDING" || checks == "EXPECTED" }
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
  /// The branch that the PR merges into.
  public var base: String?
  public var checks: String?
  public var mergeable: Mergeable?
  public var queue: TrunkQueueState?
  /// The Depot run of the head commit.
  public var depot: DepotRun?
  /// Trunk's name for the queue state, such as "Testing" or "Cancelled", when
  /// sbd read it from trunk.
  public var queueLabel: String?
  public var trunkLoginNeeded: Bool?
  /// The logins or team slugs whose review GitHub still asks for.
  public var reviewRequests: [String]?
  /// nil when GitHub has no review decision, as when the base branch
  /// requires no review.
  public var reviewDecision: ReviewDecision?
  public var approvers: [String]?
  /// When the newest approval was submitted.
  public var approvedAt: String?
  public var inMergeQueue: Bool?
  /// How sbd merges the PR. sbd sets it from the session's facts, so a
  /// summary made from the PR alone leaves it nil.
  public var mergeMethod: MergeMethod?
  /// nil when the PR has no known code owner requirement.
  public var codeOwners: CodeOwnerStatus?

  public init(_ pr: PullRequest) {
    number = pr.number
    url = pr.url
    repo = pr.repo
    title = pr.title
    state = pr.state
    status = pr.status
    base = pr.base
    checks = pr.checks
    mergeable = pr.mergeable
    queue = pr.queue
    depot = pr.headDepot
    queueLabel = pr.queueLabel
    trunkLoginNeeded = pr.trunkLoginNeeded
    reviewRequests = pr.reviewRequests
    reviewDecision = pr.reviewDecision
    approvers = pr.approvers
    approvedAt = pr.approvedAt
    inMergeQueue = pr.inMergeQueue
    codeOwners = CodeOwnerStatus(pr)
  }

  /// The PR's page, or nil unless `url` is https. Any local process can
  /// record a `pr` event, and the app opens this link when the user clicks it.
  public var link: URL? { URL(httpsOnly: url) }

  /// The PR in one line, such as "#18303 Approved, checks success, Trunk
  /// testing".
  public var line: String {
    var line = "#\(number) \(status.rawValue)\(checks.map { ", checks \($0.lowercased())" } ?? "")"
    if let queue, queue != .unknown { line += ", Trunk \((queueLabel ?? queue.rawValue).lowercased())" }
    if trunkLoginNeeded == true { line += "; trunk login needed" }
    return line
  }
}

extension URL {
  /// The URL in `string`, or nil unless its scheme is https. The app opens a
  /// PR link with NSWorkspace, which would also run a file or app URL.
  public init?(httpsOnly string: String) {
    guard let url = URL(string: string), url.scheme?.lowercased() == "https" else { return nil }
    self = url
  }
}
