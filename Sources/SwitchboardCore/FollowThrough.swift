import CryptoKit
import Foundation

/// What sbd does when a wait's condition is met, in place of resuming the holder with the note. A wait holds one
/// action, which the request's `then` names.
public struct WaitAction: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable {
    /// Lands the subject's PR the way `sb merge` does, except in a Trunk repository, where it asks the holder.
    case merge
    /// Removes the subject and its worktree, as `sb rm <subject> --worktree` does.
    case rmWorktree = "rm-worktree"
    /// Removes the subject, as `sb rm <subject>` does.
    case rm
    /// Records the wait's note as a report.
    case report

    /// What sbd did not do, after "sbd did not".
    public var skipped: String {
      switch self {
      case .merge: "merge"
      case .rmWorktree: "remove the session and its worktree"
      case .rm: "remove the session"
      case .report: "record the report"
      }
    }

    /// What `sb wait` prints after it arms the action.
    public var confirmation: String {
      switch self {
      case .merge: "sbd merges this when it's ready"
      case .rmWorktree: "sbd removes the session and its worktree when this resolves"
      case .rm: "sbd removes the session when it's done"
      case .report: "sbd records the note as a report when this resolves"
      }
    }
  }

  public var kind: Kind
  /// For `report`, makes the report an Inbox item. Nil means an info report.
  public var needsYou: Bool?

  public init(kind: Kind, needsYou: Bool? = nil) {
    self.kind = kind
    self.needsYou = needsYou
  }

  /// Refuses a wait that the action can't go on, with the shape that the action takes.
  func requireShape(of wait: Wait) throws {
    let allowed: Bool
    let shape: String
    switch kind {
    case .merge:
      allowed = wait.kind == .session && wait.state == .readyToMerge
      shape = "a session wait with state ready_to_merge"
    case .rmWorktree:
      allowed =
        (wait.kind == .session && wait.state == .done) || (wait.kind == .merge && wait.pr?.repository != nil)
      shape = "a session wait with state done, or a merge wait whose target is a PR with its repository (owner/name#N)"
    case .rm:
      allowed = wait.kind == .session && wait.state == .done
      shape = "a session wait with state done"
    case .report:
      allowed = wait.kind != .manual
      shape = "a wait of any kind but manual"
    }
    guard allowed else { throw APIError("then \(kind.rawValue) goes only on \(shape)") }
  }
}

/// Where an action stands after its wait's condition was met. A wait with no status waits for its condition. Each
/// change keeps the approval and the message key of the status before it, so a hold or a run in between loses
/// neither.
public struct ActionStatus: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable {
    /// sbd runs the action now. Only `finish` moves it on.
    case running
    /// sbd checks again at `retryAt`, or sooner when the subject's state changes.
    case held
    /// The holder got `reason` as a question, or the reply gate judge asked the user. Only an approval, a clear, an
    /// unmet outcome, or, after the judge asked, a change of the subject's state moves it on.
    case awaitingJudgment = "awaiting-judgment"
  }

  public var kind: Kind
  /// When the status began. For a hold, when sbd first held the action for `reason`.
  public var since: Int64
  /// Why sbd holds the action, or the question that it asked.
  public var reason: String?
  public var retryAt: Int64?
  /// The subject's `stateSince` when sbd held the action. A different value retries the hold.
  public var subjectSince: Int64?
  /// The PR head and the reply digest that a question about the last reply covers. An approval copies them.
  public var asked: MergeGuard.Approval?
  public var approval: MergeGuard.Approval?
  /// The hold message that sbd last sent the subject, keyed by what it was about, such as the head and the base tip.
  public var messageKey: String?
  /// The PR head and the reply digest that the reply gate judge last answered. sbd calls the judge once per pair.
  public var judged: MergeGuard.Approval?

  public init(kind: Kind, since: Int64) {
    self.kind = kind
    self.since = since
  }

  /// Whether a met outcome starts the action again. A hold whose retry time came, or whose subject's state changed
  /// since, does. A question does only when it stored the subject's state, as the judge's `ask` does, and that
  /// state changed since. A question to the holder stores none.
  public func retries(now: Int64, subjectSince: Int64?) -> Bool {
    let changed = subjectSince != nil && subjectSince != self.subjectSince
    switch kind {
    case .running: return false
    case .held: return (retryAt ?? 0) <= now || changed
    case .awaitingJudgment: return parkedByJudge && changed
    }
  }

  /// Whether the judge's `ask` parked the action, so the holder's conversation never saw a question. A question to
  /// the holder stores no `subjectSince`. A question stored before the judge existed can keep the `subjectSince` of
  /// an earlier hold, but it has no `judged`.
  public var parkedByJudge: Bool { kind == .awaitingJudgment && judged != nil && subjectSince != nil }
}

/// Decides whether sbd merges the subject's PR for a `merge` action. It acts only when it can show that the commit
/// GitHub merges is the head that sbd read live, that its checks passed, that it contains the base's tip, that the base
/// is not red, that no earlier merge in the repository shares its files, and that the holder approved the last reply
/// at that head. Anything unknown holds.
public enum MergeGuard {
  /// The PR as `gh pr view` read it just before the merge.
  public struct LivePR: Equatable, Sendable {
    public var head: String
    public var state: PRState
    public var draft: Bool
    public var mergeable: Mergeable?
    public var base: String
    /// The head's check rollup, or nil without checks.
    public var rollup: ChecksRollup?
    /// The merge commit of a merged PR, or nil when GitHub has none.
    public var mergeCommit: String?

    public init(
      head: String, state: PRState, draft: Bool, mergeable: Mergeable?, base: String, rollup: ChecksRollup?,
      mergeCommit: String? = nil
    ) {
      self.head = head
      self.state = state
      self.draft = draft
      self.mergeable = mergeable
      self.base = base
      self.rollup = rollup
      self.mergeCommit = mergeCommit
    }
  }

  /// The holder's answer that the last reply leaves nothing for the user, bound to the head and the reply it saw.
  public struct Approval: Codable, Equatable, Sendable {
    public var head: String
    public var replyDigest: String

    public init(head: String, replyDigest: String) {
      self.head = head
      self.replyDigest = replyDigest
    }
  }

  /// The last PR that sbd merged into the base. Nil fields are unknown.
  public struct SbdMerge: Equatable, Sendable {
    public var commit: String?
    public var files: Set<String>?

    public init(commit: String?, files: Set<String>?) {
      self.commit = commit
      self.files = files
    }
  }

  /// What sbd read. Each optional read is nil when it failed.
  public struct Input: Sendable {
    public var mergeRepos: [String]
    /// The subject's verdict, or nil when the subject is gone or being deleted.
    public var verdict: SwitchboardCore.Verdict?
    public var facts: SessionFacts
    public var live: LivePR?
    public var behindBy: Int?
    public var baseTip: String?
    public var baseRollup: ChecksRollup?
    public var files: Set<String>?
    /// The files of each earlier pending merge in the repository.
    public var earlierFiles: [Set<String>?]
    public var lastSbdMerge: SbdMerge?
    public var approval: Approval?

    public init(
      mergeRepos: [String], verdict: SwitchboardCore.Verdict?, facts: SessionFacts, live: LivePR?, behindBy: Int?,
      baseTip: String?, baseRollup: ChecksRollup?, files: Set<String>?, earlierFiles: [Set<String>?],
      lastSbdMerge: SbdMerge?, approval: Approval?
    ) {
      self.mergeRepos = mergeRepos
      self.verdict = verdict
      self.facts = facts
      self.live = live
      self.behindBy = behindBy
      self.baseTip = baseTip
      self.baseRollup = baseRollup
      self.files = files
      self.earlierFiles = earlierFiles
      self.lastSbdMerge = lastSbdMerge
      self.approval = approval
    }
  }

  public enum Verdict: Equatable, Sendable {
    case act
    /// Not yet. `message`, when set, goes to the subject.
    case hold(reason: String, message: String?)
    /// The subject is no longer Ready to merge, so the wait waits for its condition again.
    case rearm(reason: String)
    case judgment(question: String)
  }

  /// The checks that need no live read, in order: the allowlist, the subject, its Ready to merge verdict, the
  /// merge method, and the review threads. It returns nil when they all pass.
  public static func checkFacts(mergeRepos: [String], verdict: SwitchboardCore.Verdict?, facts: SessionFacts)
    -> Verdict?
  {
    guard let pr = facts.pr else { return .hold(reason: "sbd has not read the session's PR", message: nil) }
    guard OperatorSettings(mergeRepos: mergeRepos).mergesIn(pr.repo) else {
      return .judgment(
        question: "operator.mergeRepos in config.json doesn't list \(pr.repo), so sbd won't merge #\(pr.number). "
          + "The user merges it")
    }
    guard let verdict else { return .hold(reason: "the session is gone or being deleted", message: nil) }
    guard verdict.state == .readyToMerge else {
      return .rearm(reason: "the session is \(verdict.state.title), not Ready to merge")
    }
    guard facts.mergeMethod != .unknown else {
      return .hold(reason: "sbd can't tell yet how \(pr.repo) merges", message: nil)
    }
    guard facts.mergeMethod != .trunk else {
      return .judgment(
        question: "\(pr.repo) merges through Trunk's queue, and a /trunk merge comment can't name the head that sbd "
          + "checked, so sbd won't enqueue #\(pr.number). The user enqueues it")
    }
    guard let details = pr.mergeDetails else {
      return .hold(reason: "sbd has not read the review threads of #\(pr.number)", message: nil)
    }
    guard details.threadsRead >= details.threads else {
      return .hold(reason: "sbd could not read every review thread of #\(pr.number)", message: nil)
    }
    guard details.openThreads == 0 else {
      return .hold(reason: "#\(pr.number) has unresolved review threads", message: nil)
    }
    return nil
  }

  /// Every check in order. `runMerge` runs the stages one at a time, so a stage that holds spares the live reads of
  /// the stages after it.
  public static func check(_ input: Input) -> Verdict {
    checkFacts(mergeRepos: input.mergeRepos, verdict: input.verdict, facts: input.facts) ?? checkLive(input)
      ?? checkBase(input) ?? checkFiles(input) ?? checkReply(input)
  }

  /// The checks of the live read of the PR, which run after `checkFacts`. It returns nil when they all pass.
  public static func checkLive(_ input: Input) -> Verdict? {
    guard let pr = input.facts.pr else { return hold("sbd has not read the session's PR") }
    let n = "#\(pr.number)"
    guard let live = input.live else { return hold("the live read of \(n) failed") }
    guard !live.head.isEmpty, live.head == pr.headSha else {
      return hold("the head of \(n) moved after the poller read it")
    }
    guard live.state == .open else { return hold("GitHub shows \(n) as \(live.state.rawValue.lowercased())") }
    guard !live.draft else { return hold("GitHub shows \(n) as a draft") }
    guard let mergeable = live.mergeable, mergeable != .unknown else {
      return hold("GitHub has not computed whether \(n) merges cleanly")
    }
    guard mergeable == .mergeable else { return hold("\(n) conflicts with its base") }
    guard let defaultBranch = pr.defaultBranch else { return hold("sbd has not read the default branch of \(pr.repo)") }
    guard live.base == defaultBranch else {
      return .judgment(question: "\(n) targets \(live.base), not \(defaultBranch), so sbd won't merge it")
    }
    guard live.rollup == .passed else {
      let state =
        switch live.rollup {
        case .failed?: "failing"
        case .running?: "running"
        default: "missing"
        }
      return hold("the checks of \(n) at \(short(live.head)) are \(state)")
    }
    return nil
  }

  /// The checks of the base branch, which run after `checkLive`: the PR contains the base's tip, and the tip is not
  /// red. It returns nil when they pass.
  public static func checkBase(_ input: Input) -> Verdict? {
    guard let pr = input.facts.pr, let live = input.live else { return hold("sbd has not read the PR live") }
    let n = "#\(pr.number)"
    guard let behind = input.behindBy else { return hold("sbd could not read whether \(n) contains \(live.base)") }
    guard behind == 0 else {
      return hold(
        "\(n) is behind \(live.base)",
        "Merge origin/\(live.base) into your branch, resolve any conflicts, run the tests, and push.")
    }
    guard let baseTip = input.baseTip else { return hold("sbd could not read the tip of \(live.base)") }
    let tip = "\(live.base) at \(short(baseTip))"
    switch input.baseRollup {
    case .passed?, .running?:
      return nil
    case .failed?:
      return .judgment(question: "\(tip) is red, so sbd won't merge \(n) onto it. Start a fix, or report it")
    case nil:
      return hold("sbd could not read the checks of \(tip)")
    }
  }

  /// sbd's last merge in the repository when the base's checks still run on it, or nil. `checkFiles` then compares
  /// its files with the PR's.
  public static func ownMergeUnderCI(_ input: Input) -> SbdMerge? {
    guard input.baseRollup == .running, let merged = input.lastSbdMerge,
      merged.commit == nil || merged.commit == input.baseTip
    else { return nil }
    return merged
  }

  /// The checks of the PR's files, which run after `checkBase`: no file is shared with sbd's own merge while the
  /// base's checks run on it, or with an earlier merge in the repository. They read `files` only when
  /// `ownMergeUnderCI` gives a merge or `earlierFiles` is not empty. It returns nil when they pass.
  public static func checkFiles(_ input: Input) -> Verdict? {
    guard let pr = input.facts.pr, let live = input.live else { return hold("sbd has not read the PR live") }
    let n = "#\(pr.number)"
    if let merged = ownMergeUnderCI(input) {
      let tip = "\(live.base) at \(short(input.baseTip ?? ""))"
      guard let mine = input.files, let theirs = merged.files else {
        return hold("CI runs on \(tip) after sbd's last merge, and sbd can't compare its files with \(n)")
      }
      if !mine.isDisjoint(with: theirs) {
        return hold("CI runs on \(tip) after sbd's last merge, which shared files with \(n)")
      }
    }
    if !input.earlierFiles.isEmpty {
      guard let mine = input.files else { return hold("sbd could not read the files of \(n)") }
      for theirs in input.earlierFiles {
        guard let theirs else { return hold("sbd could not read the files of an earlier merge in \(pr.repo)") }
        if !mine.isDisjoint(with: theirs) {
          return hold("an earlier merge in \(pr.repo) shares files with \(n)")
        }
      }
    }
    return nil
  }

  /// The last check, after `checkFiles`: the holder approved the last reply at the live head.
  public static func checkReply(_ input: Input) -> Verdict {
    guard let pr = input.facts.pr, let live = input.live else { return hold("sbd has not read the PR live") }
    let digest = replyDigest(input.facts.lastReply)
    guard let approval = input.approval, approval.head == live.head, approval.replyDigest == digest else {
      return .judgment(question: replyQuestion("Every check passed for #\(pr.number) at \(short(live.head))."))
    }
    return .act
  }

  /// The question about the session's last reply, after `lead`, which says why sbd asks. The operator's role prompt
  /// tells the operator how to answer it.
  public static func replyQuestion(_ lead: String) -> String {
    "\(lead) Does the session's last reply ask the user a question, leave a decision for the user, or say that /go "
      + "did not finish?"
  }

  private static func hold(_ reason: String, _ message: String? = nil) -> Verdict {
    .hold(reason: reason, message: message)
  }

  /// The approval that would let `input` act, when the reply is all that it lacks, or nil.
  public static func replyGate(_ input: Input) -> Approval? {
    guard let live = input.live else { return nil }
    var approved = input
    approved.approval = Approval(head: live.head, replyDigest: replyDigest(input.facts.lastReply))
    return check(approved) == .act ? approved.approval : nil
  }

  /// The SHA-256 of the reply in hex. No reply gives a word that no hex digest equals.
  public static func replyDigest(_ reply: String?) -> String {
    guard let reply else { return "no-reply" }
    return SHA256.hash(data: Data(reply.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func short(_ sha: String) -> String { String(sha.prefix(7)) }
}

/// Decides whether sbd removes the subject of an `rm` or `rm-worktree` action now. A worktree goes only after the
/// subject's PR merged. A running turn or a message on its way holds the removal, because `remove` would stop the
/// turn. `remove` still runs its own checks after this one.
public enum RemovalGuard {
  /// What sbd read about the subject on the state queue.
  public struct Input: Equatable, Sendable {
    public var name: String
    public var exists: Bool
    /// The removal job holds the subject, `rm` is removing it, or a start or a merge runs on it.
    public var busy: Bool
    public var host: String?
    public var worktree: Bool
    public var pr: PullRequest?
    public var turnRunning: Bool
    public var messageWaiting: Bool

    public init(
      name: String, exists: Bool, busy: Bool, host: String?, worktree: Bool, pr: PullRequest?, turnRunning: Bool,
      messageWaiting: Bool
    ) {
      self.name = name
      self.exists = exists
      self.busy = busy
      self.host = host
      self.worktree = worktree
      self.pr = pr
      self.turnRunning = turnRunning
      self.messageWaiting = messageWaiting
    }
  }

  public enum Verdict: Equatable, Sendable {
    case remove
    /// The subject is already gone.
    case gone
    case hold(reason: String)
    case judgment(question: String)
  }

  public static func check(_ input: Input) -> Verdict {
    let name = input.name
    guard input.exists else { return .gone }
    if input.busy { return .hold(reason: "\(name) is busy or being deleted") }
    if let host = input.host {
      return .judgment(question: "\(name) runs on \(host), and sbd removes only sessions on this Mac")
    }
    if input.worktree {
      guard let pr = input.pr else {
        return .judgment(question: "\(name) has no PR, so sbd won't remove its worktree")
      }
      guard pr.state == .merged else {
        return .judgment(
          question: "#\(pr.number) of \(name) is \(pr.state.rawValue.lowercased()), not merged, so sbd won't remove "
            + "its worktree")
      }
    }
    if input.turnRunning || input.messageWaiting { return .hold(reason: "the turn of \(name) runs") }
    return .remove
  }
}

/// The `operator` settings in config.json.
public struct OperatorSettings: Codable, Equatable, Sendable {
  /// The repositories, as `owner/name`, where sbd may merge a PR for a wait's action. The user edits this list.
  public var mergeRepos: [String] = []
  /// How long a held action waits before sbd checks it again.
  public var holdRetrySeconds = 120
  /// How long an action may stay held for one reason before sbd asks for judgment.
  public var holdLimitSeconds = 21600
  /// The model of the operator's claude and of every judge call.
  public var model = OperatorSettings.defaultModel
  /// How long a top-up's pick may run before sbd sends the schedule's prompt instead.
  public var topupTimeoutSeconds = 120
  /// The turns after which sbd starts a fresh operator conversation. 0 turns the turn limit off.
  public var maxTurns = 20
  /// The age, in seconds, after which sbd starts a fresh operator conversation. 0 turns the age limit off.
  public var resetEverySeconds = 86400
  /// The auto-compact window of the operator's claude, as `ManagerSettings.autoCompactWindow` describes it.
  public var autoCompactWindow = AutoCompact.defaultWindow

  /// The model that the operator and the judges run unless config.json sets one.
  public static let defaultModel = "sonnet"

  public init(mergeRepos: [String] = []) {
    self.mergeRepos = mergeRepos
  }

  /// The key that `model` replaced. A config.json that has it and no `model` keeps the model it chose.
  private enum LegacyKeys: String, CodingKey { case judgeModel }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = OperatorSettings()
    mergeRepos = try c.decodeIfPresent([String].self, forKey: .mergeRepos) ?? d.mergeRepos
    holdRetrySeconds = try c.decodeIfPresent(Int.self, forKey: .holdRetrySeconds) ?? d.holdRetrySeconds
    holdLimitSeconds = try c.decodeIfPresent(Int.self, forKey: .holdLimitSeconds) ?? d.holdLimitSeconds
    let legacy = try decoder.container(keyedBy: LegacyKeys.self)
    model =
      try c.decodeIfPresent(String.self, forKey: .model)
      ?? legacy.decodeIfPresent(String.self, forKey: .judgeModel) ?? d.model
    topupTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .topupTimeoutSeconds) ?? d.topupTimeoutSeconds
    maxTurns = try c.decodeIfPresent(Int.self, forKey: .maxTurns) ?? d.maxTurns
    resetEverySeconds = try c.decodeIfPresent(Int.self, forKey: .resetEverySeconds) ?? d.resetEverySeconds
    autoCompactWindow = try c.decodeIfPresent(Int.self, forKey: .autoCompactWindow) ?? d.autoCompactWindow
  }

  /// Whether sbd may merge a PR of `repository`. The match ignores case.
  public func mergesIn(_ repository: String) -> Bool {
    mergeRepos.contains { Dependencies.sameRepo($0, repository) }
  }
}
