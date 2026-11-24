import Foundation

extension Schedule {
  /// A gate that sbd checks on each due time instead of sending the prompt.
  /// It counts the group's active work sessions in the repository and starts
  /// sessions from the open issues and follow-ups when the group is short.
  public struct Gate: Codable, Equatable, Sendable {
    /// One check of the gate. The Loops tab and `sb schedule ls` show the last one.
    public struct Check: Codable, Equatable, Sendable {
      /// Agents read these raw values in `sb schedule ls --json`.
      public enum Result: String, Codable, Sendable {
        case gated
        case started
        case prompted
        case failed
      }

      /// Milliseconds since the epoch.
      public var t: Int64
      public var result: Result
      public var active: Int
      public var target: Int
      public var started: [String]
      public var skipped: [Skip]
      public var error: String?

      public init(
        t: Int64, result: Result, active: Int, target: Int, started: [String], skipped: [Skip], error: String? = nil
      ) {
        self.t = t
        self.result = result
        self.active = active
        self.target = target
        self.started = started
        self.skipped = skipped
        self.error = error
      }

      /// A check at `now` that counts `status`'s active sessions.
      public init(
        _ result: Result, status: QueueStatus, now: Int64, started: [String] = [], skipped: [Skip] = [],
        error: String? = nil
      ) {
        self.init(
          t: now, result: result, active: status.counted.count, target: status.target, started: started,
          skipped: skipped, error: error)
      }
    }

    /// A candidate that a check passed over, and why.
    public struct Skip: Codable, Equatable, Sendable {
      /// `#<number>` or `followup:<session id>`.
      public var ref: String
      public var reason: String

      public init(ref: String, reason: String) {
        self.ref = ref
        self.reason = reason
      }
    }

    public static let targets = 1...20

    /// The group's id.
    public var group: String
    /// owner/name
    public var repo: String
    public var target: Int
    /// The prompt of each session that the gate starts from an issue, with `IssuePreset`'s placeholders.
    public var template: String
    /// How to rank the candidates, for the pick.
    public var rubric: String
    /// The ids of the sessions that the gate started, that sbd still has, and whose merge wait sbd hasn't armed. sbd
    /// arms a session's merge wait once, so it doesn't arm the wait again after the Operator clears it.
    public var started: [String]?
    /// The due times that the gate closed since the schedule's last run.
    public var gated: Int?
    public var last: Check?

    public init(
      group: String, repo: String, target: Int, template: String, rubric: String,
      started: [String]? = nil, gated: Int? = nil, last: Check? = nil
    ) {
      self.group = group
      self.repo = repo
      self.target = target
      self.template = template
      self.rubric = rubric
      self.started = started
      self.gated = gated
      self.last = last
    }

    /// The prompt that a gated schedule stores when its request has none.
    public static func defaultPrompt(groupName: String, repo: String, target: Int) -> String {
      "Work queue tick for \(groupName) in \(repo): merge and clean up what is finished, then top up to \(target) working sessions from the open issues and follow-ups, most important first, by the rubric and template below."
    }

    /// What sbd sends to the schedule's session when the gate opens or the
    /// top-up fails: the failure, the status lines, the prompt, then the
    /// rubric and the template.
    public func fallbackMessage(status: QueueStatus, prompt: String, failure: String? = nil) -> String {
      let head = (failure.map { ["The top-up failed: \(oneLine($0, max: 300))"] } ?? []) + status.lines
      return """
        \(head.joined(separator: "\n"))

        \(prompt)

        The rubric:
        <rubric>
        \(rubric)
        </rubric>

        The template for each session's prompt:
        <template>
        \(template)
        </template>
        """
    }

    /// Such as `topup Switchboard haacked/switchboard 3/5 · checked 2m ago: gated`.
    public func statusText(groupName: String, now: Int64 = nowMs()) -> String {
      guard let check = checkText(now: now) else {
        return "topup \(groupName) \(repo) · target \(target) · never checked"
      }
      return "topup \(groupName) \(repo) \(check)"
    }

    /// Such as `3/5 · checked 2m ago: gated`, or nil before the first check.
    public func checkText(now: Int64 = nowMs()) -> String? {
      guard let last else { return nil }
      let error = last.error.map { ": \($0)" } ?? ""
      return "\(last.active)/\(last.target) · checked \(ago(last.t, now: now)) ago: \(last.result.rawValue)\(error)"
    }
  }
}

/// The work sessions of a top-up gate's group, sorted by what each means for the gate.
public struct QueueStatus: Equatable, Sendable {
  public struct Row: Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: SessionKind
    public var group: String?
    /// owner/name, or nil when sbd hasn't read it or the checkout's origin isn't on GitHub. It is the gate's
    /// repository when the session's PR, issue link, or follow-up is in it, whatever the origin names.
    public var repository: String?
    /// sbd has read the session's checkout and its origin, and neither read failed. A nil `repository` with this set
    /// is a session off GitHub.
    public var repositoryRead: Bool
    public var markedDone: Bool
    public var paused: Bool
    public var removing: Bool
    public var state: AttentionState
    /// The session's host is not connected or not reconciled, so its facts may be stale.
    public var unreadHost: Bool
    public var prMerged: Bool
    /// A wait on any holder will merge the session's PR.
    public var hasMergeAction: Bool
    /// A wait on any holder will remove the session's worktree or the session.
    public var hasRemovalAction: Bool
    /// False for a follow-up that waits to start.
    public var started: Bool
    /// The session's start waits for a free slot under the live cap, and a message waits for that start. The message
    /// runs once a slot frees, so the session's state may read Needs you until then.
    public var startWaitingForSlot: Bool

    public init(
      id: String, name: String, kind: SessionKind, group: String?, repository: String?, repositoryRead: Bool,
      markedDone: Bool, paused: Bool, removing: Bool, state: AttentionState, unreadHost: Bool, prMerged: Bool,
      hasMergeAction: Bool, hasRemovalAction: Bool, started: Bool, startWaitingForSlot: Bool
    ) {
      self.id = id
      self.name = name
      self.kind = kind
      self.group = group
      self.repository = repository
      self.repositoryRead = repositoryRead
      self.markedDone = markedDone
      self.paused = paused
      self.removing = removing
      self.state = state
      self.unreadHost = unreadHost
      self.prMerged = prMerged
      self.hasMergeAction = hasMergeAction
      self.hasRemovalAction = hasRemovalAction
      self.started = started
      self.startWaitingForSlot = startWaitingForSlot
    }

    var label: String { sessionMention(name: name, id: id) }
  }

  public enum Decision: Equatable, Sendable {
    /// The group has its target, and nothing needs the Operator.
    case gated
    case topup(k: Int)
    /// Send the schedule's prompt. Each reason names a session.
    case open(reasons: [String])
  }

  public var repo: String
  public var target: Int
  public var counted: [Row]
  public var unknown: [Row]
  public var needsAttention: [Row]
  /// One per row of `unknown` and then of `needsAttention`.
  public var reasons: [String]

  /// Sorts the rows for the gate. It reads only the started work sessions in
  /// the gate's group. Any doubt about a row opens the gate, so the gate skips
  /// a due time only when it can show that nothing needs doing.
  public static func compute(_ rows: [Row], gate: Schedule.Gate) -> QueueStatus {
    var status = QueueStatus(
      repo: gate.repo, target: gate.target, counted: [], unknown: [], needsAttention: [], reasons: [])
    var attentionReasons: [String] = []
    for row in rows where row.kind == .work && row.group == gate.group && row.started {
      // The stored repository of a row on an unread host may be stale, so the repository check comes after this one.
      if let reason = unknownReason(row) {
        status.unknown.append(row)
        status.reasons.append("\(row.label): \(reason)")
        continue
      }
      guard let repository = row.repository, Dependencies.sameRepo(repository, gate.repo) else { continue }
      if let reason = attentionReason(row) {
        status.needsAttention.append(row)
        attentionReasons.append("\(row.label): \(reason)")
      } else if counts(row) {
        status.counted.append(row)
      }
    }
    status.reasons += attentionReasons
    return status
  }

  private static func unknownReason(_ row: Row) -> String? {
    if row.unreadHost { return "its host is not connected, so sbd can't read its state" }
    // A row that sbd has read and found off GitHub is outside the gate's repository, so `compute` skips it.
    guard let repository = row.repository else {
      return row.repositoryRead ? nil : "sbd hasn't read its repository yet"
    }
    // A repository that isn't owner/name can't show that the row is outside the gate's repository.
    if !Issues.validRepo(repository) { return "sbd can't read its repository \(repository)" }
    return nil
  }

  private static func attentionReason(_ row: Row) -> String? {
    if row.state == .readyToMerge && !row.hasMergeAction { return "Ready to merge, and no wait will merge it" }
    guard !row.hasRemovalAction else { return nil }
    if row.state == .done { return "done, and no wait will remove its worktree" }
    if row.prMerged { return "its PR merged, and no wait will remove its worktree" }
    return nil
  }

  private static func counts(_ row: Row) -> Bool {
    guard !row.markedDone && !row.paused && !row.removing && !row.prMerged else { return false }
    return row.startWaitingForSlot || ![.done, .needsYou, .notStarted].contains(row.state)
  }

  public var decision: Decision {
    if !reasons.isEmpty { return .open(reasons: reasons) }
    return counted.count >= target ? .gated : .topup(k: target - counted.count)
  }

  /// Why a top-up that has started the sessions `started` can't start one more, or nil when it can. It counts each
  /// started session as active and leaves its row out, because sbd may not have read its repository yet.
  public static func startRefusal(_ rows: [Row], gate: Schedule.Gate, started: [String]) -> String? {
    let full = "the group has its target of \(gate.target) active sessions"
    switch compute(rows.filter { !started.contains($0.id) }, gate: gate).decision {
    case .open(let reasons): return "the gate opened: \(reasons.joined(separator: "; "))"
    case .gated: return full
    case .topup(let k): return started.count < k ? nil : full
    }
  }

  /// The status that the fallback message starts with.
  public var lines: [String] {
    ["Work queue: \(counted.count)/\(target) active sessions in \(repo)."] + reasons.map { "- \($0)" }
  }
}

/// The issues and follow-ups that a top-up may start, and the issues it passed over.
public struct TopupCandidates: Equatable, Sendable {
  public enum Candidate: Equatable, Sendable {
    case issue(InboxIssue)
    case followup(id: String, prompt: String)

    /// `#<number>` or `followup:<session id>`, as the pick names it.
    public var ref: String {
      switch self {
      case .issue(let issue): "#\(issue.number)"
      case .followup(let id, _): "followup:\(id)"
      }
    }
  }

  /// A session whose branch, issue link, or PR may cover an issue.
  public struct SessionRow: Equatable, Sendable {
    /// owner/name of the session's checkout, or nil when sbd hasn't read it. A session without a repository covers
    /// issues as if it worked in the gate's repository, because the top-up never guesses that an issue is uncovered.
    public var repository: String?
    public var branch: String?
    public var prNumber: Int?
    public var issue: IssueRef?
    /// The issues that the session's PR closes.
    public var closesIssues: [IssueRef]?

    public init(repository: String?, branch: String?, prNumber: Int?, issue: IssueRef?, closesIssues: [IssueRef]?) {
      self.repository = repository
      self.branch = branch
      self.prNumber = prNumber
      self.issue = issue
      self.closesIssues = closesIssues
    }
  }

  /// An open PR of the gate's repository.
  public struct OpenPR: Equatable, Sendable {
    public var number: Int
    public var headRefName: String
    public var closes: [IssueRef]

    public init(number: Int, headRefName: String, closes: [IssueRef]) {
      self.number = number
      self.headRefName = headRefName
      self.closes = closes
    }
  }

  public var candidates: [Candidate]
  public var skips: [Schedule.Gate.Skip]

  /// The open issues of `repo` that no session or open PR covers, then the
  /// follow-ups of `repo` and `group` that wait to start, aren't marked done,
  /// and whose trigger has fired or is manual. An issue that neither the
  /// viewer nor a teammate wrote is a skip, because the top-up starts its
  /// sessions unattended. An unknown viewer trusts no one.
  public static func build(
    repo: String, group: String, issues: [InboxIssue], openPRs: [OpenPR], sessions: [SessionRow],
    followups: [Session], viewer: String?, team: IssueTeam
  ) -> TopupCandidates {
    var covered = Set<String>()
    func cover(_ repo: String, _ number: Int?) {
      if let number { covered.insert(InboxIssue.id(repo, number)) }
    }
    for session in sessions {
      let repository = session.repository ?? repo
      cover(repository, Issues.branchNumber(session.branch, prNumber: session.prNumber))
      for ref in [session.issue].compactMap({ $0 }) + (session.closesIssues ?? []) {
        cover(ref.repo ?? repository, ref.number)
      }
    }
    for pr in openPRs {
      cover(repo, Issues.branchNumber(pr.headRefName, prNumber: pr.number))
      for ref in pr.closes { cover(ref.repo ?? repo, ref.number) }
    }

    var result = TopupCandidates(candidates: [], skips: [])
    for issue in issues where Dependencies.sameRepo(issue.repo, repo) && !covered.contains(issue.id) {
      if let reason = distrust(issue, viewer: viewer, team: team) {
        result.skips.append(Schedule.Gate.Skip(ref: Candidate.issue(issue).ref, reason: reason))
      } else {
        result.candidates.append(.issue(issue))
      }
    }
    for session in followups where session.waitsToStart && !session.done && session.group == group {
      guard let followup = session.followup, followup.trigger.kind == .manual || followup.ready != nil,
        let repository = followup.repository, Dependencies.sameRepo(repository, repo)
      else { continue }
      result.candidates.append(.followup(id: session.id, prompt: followup.prompt))
    }
    return result
  }

  /// Why the top-up doesn't trust the issue's author, or nil when it does.
  /// `IssueInbox.trusts` trusts the team without a viewer, so this checks the viewer first.
  private static func distrust(_ issue: InboxIssue, viewer: String?, team: IssueTeam) -> String? {
    guard let viewer else { return "sbd doesn't know your GitHub login yet, so it trusts no author" }
    guard let author = issue.author else { return "written by an unknown author, who isn't you or a teammate" }
    return IssueInbox(viewer: viewer, team: team).trusts(issue)
      ? nil : "written by \(author), who isn't you or a teammate"
  }
}
