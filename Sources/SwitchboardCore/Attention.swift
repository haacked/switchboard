import Foundation

/// A tool call that the main session waits on: a running tool, a permission
/// prompt, or a question.
public struct ToolCall: Codable, Equatable, Sendable {
  public var tool: String
  public var summary: String
  /// Milliseconds since the epoch.
  public var since: Int64
  /// The call's tool_use_id. PermissionRequest carries none.
  public var id: String?
  /// The call's input, which pairs a PermissionRequest with its PostToolUse.
  public var input: JSON?
}

/// What a session's events say about it. sbd applies each event as it
/// arrives. At startup, sbd applies the whole event log again.
public struct SessionFacts: Codable, Equatable, Sendable {
  /// True from claude's SessionStart until claude ends or exits.
  public var live = false
  public var turnRunning = false
  public var turnStarted: Int64?
  public var runningTool: ToolCall?
  public var openPermission: ToolCall?
  public var openQuestion: ToolCall?
  /// The number of prompts that the user sent. A subagent's result also
  /// arrives as a prompt. This count leaves it out.
  public var prompts = 0
  public var lastReply: String?
  public var lastActivity: Int64 = 0
  /// When claude last reported SessionStart.
  public var lastStart: Int64?
  /// The transcript that the last SessionStart named, in the account that
  /// claude runs under. Claude creates the file at the conversation's first
  /// prompt.
  public var transcriptPath: String?
  /// When sbd last started or resumed claude.
  public var lastLaunch: Int64?
  /// Background jobs that run under claude, as the last `job` event counted
  /// them. A job sends no hooks, so sbd's tick finds it in the process list.
  public var jobs = 0
  /// Subagents that started and have not stopped.
  public var subagents: Set<String> = []
  /// When the state last changed. `Attention.track` sets it.
  public var stateSince: Int64 = 0
  public var lastState: AttentionState?
  /// The reason line of a wait that resolved with `notify`. The next prompt,
  /// or a new wait, clears it.
  public var waitOutcome: String?
  /// Open and deferred permission prompts and questions, oldest first.
  public var cards: [Card] = []
  /// Messages that sbd sent on its own, such as a wait's outcome, until
  /// claude reports each one as a prompt.
  public var sbdMessages: [String] = []
  /// The session's PR, as the GitHub poller last read it.
  public var pr: PullRequest?
  /// The PR's comments from `GitHub.bodyAuthors`, with their bodies.
  public var prComments: [PRComment] = []
  /// The uncommitted files in the folder, which the poller counts once the
  /// PR has merged or closed.
  public var dirty: Int?
  /// Whether the folder no longer exists, as the poller found when its count
  /// failed. A count that failed for another reason leaves this false.
  public var folderGone = false
  /// What the cleanup checks of the last `worktree` event found.
  public var cleanupChecked: CleanupStatus?
  /// The removal that a `cleanup` event recorded.
  public var cleanedUp: CleanupStatus?
  /// Whether `sb cleanup` can remove the worktree, or whether it did. The
  /// poller records the count before the finished PR's `pr` event, so this
  /// returns the checks' result only once the PR reads merged and the count
  /// reads clean.
  public var cleanup: CleanupStatus? {
    if let cleanedUp { return cleanedUp }
    guard pr?.state == .merged, dirty == 0 else { return nil }
    return cleanupChecked
  }
  /// The id of the last Stop event, which keys the turn's triage summary.
  public var lastStop: Int64 = 0
  /// The summary of the turn that ended at `lastStop`, once a `triage` event
  /// recorded it.
  public var triage: TriageSummary?
  /// The card that the session wrote with `sb summary set` during its
  /// current turn, and the id of its event.
  public var sessionSummary: TriageSummary?
  public var sessionSummaryId: Int64 = 0
  /// When sbd called the model for a summary, within the last hour.
  public var summaryCalls: [Int64] = []
  /// When the user last sent the session a prompt or answered its card, or 0.
  public var lastTouched: Int64 = 0
  /// When sbd continued the session on its own, within the last hour.
  public var autoContinues: [Int64] = []
  /// The PRs that the session's open PR waits on, as the poller last found them.
  public var dependencies: [Dependency] = []
  /// What a docket row's `docket` events say.
  public var docket = DocketStatus()
  /// The last merge that sbd ran or the user dismissed.
  public var merge: MergeAttempt?
  /// The last review request that sbd ran or the user dismissed.
  public var reviewRequest: ReviewRequestAttempt?
  /// Claude Code's permission mode, as the last main-session hook or launch
  /// reported it. SessionStart carries none, so a launch without a mode
  /// leaves it unknown until the next hook.
  public var permissionMode: String?
  /// When a `pr` event first showed the PR open and not a draft. An event
  /// with a draft, a merged or closed PR, or no PR clears it.
  public var readySince: Int64?

  /// The hook events that sbd's settings file subscribes claude to.
  public static let hookKinds = [
    "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
    "PermissionRequest", "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop",
  ]

  /// The kinds of the events that move `lastActivity`, which holds off the
  /// idle stop and the Stale state. They are claude's hooks, and the sbd
  /// events that the user, the session, or a launch caused. Every other kind,
  /// such as a poller's report, sbd's view of the process, or a kind that sbd
  /// starts to record later, does not count. `idle` stands in for a Stop that
  /// claude did not send. A refusal in the pane sends no hook, so
  /// `dialog_closed` and `card_closed` can be the only record of the answer.
  static let activityKinds = Set(hookKinds).union([
    "created", "imported", "followup", "started", "resumed", "followup-started", "sent", "answered",
    "dialog_closed", "card_closed", "wait", "wait-cleared", "note", "note-removed", "done", "undone",
    "account-moved", "idle",
  ])

  public init() {}

  public mutating func apply(_ event: Event) {
    let d = event.data
    if SessionFacts.activityKinds.contains(event.kind) { lastActivity = max(lastActivity, event.t) }
    let userPrompt = isUserPrompt(event)
    applyWait(event, userPrompt: userPrompt)
    // A subagent's tool calls don't change what the main session waits on.
    let fromSubagent = event.fromSubagent
    let tool = d["tool_name"]?.string ?? ""
    if !fromSubagent, let mode = d["permission_mode"]?.string { permissionMode = mode }
    switch event.kind {
    case "SessionStart":
      live = true
      lastStart = event.t
      transcriptPath = d["transcript_path"]?.string
    case "running":
      live = true
    case "account-moved":
      transcriptPath = nil
    case "docket":
      docket.apply(d)
    case "started", "resumed":
      lastLaunch = event.t
      permissionMode = d["permission_mode"]?.string
    case "imported":
      // The transcript's last line, not the import, is the session's last activity.
      if let t = d["lastActivity"]?.int { lastActivity = Int64(t) }
      lastReply = d["lastReply"]?.string
      // A reply means that the user sent a prompt before it.
      if d["hasReplies"]?.bool == true { prompts = max(prompts, 1) }
    case "job":
      jobs = d["count"]?.int ?? 0
    case "SessionEnd", "stopped", "exited":
      live = false
      jobs = 0
      endTurn()
      subagents = []
    case "UserPromptSubmit":
      if userPrompt { prompts += 1 }
      startTurn(event.t)
      runningTool = nil
      openPermission = nil
      openQuestion = nil
    case "PreToolUse" where !fromSubagent:
      startTurn(event.t)
      let call = Attention.call(tool, d, event.t)
      if tool == "AskUserQuestion" {
        openQuestion = call
      } else if d["tool_input"]?["run_in_background"]?.bool != true {
        runningTool = call
      }
    case "PermissionRequest" where !fromSubagent:
      let call = Attention.call(tool, d, event.t)
      if tool == "AskUserQuestion" {
        if openQuestion == nil { openQuestion = call }
      } else {
        openPermission = call
      }
    case "PostToolUse" where !fromSubagent, "PostToolUseFailure" where !fromSubagent:
      let id = d["tool_use_id"]?.string
      if tool == "AskUserQuestion" { openQuestion = nil }
      if let running = runningTool, Attention.same(running, tool, id) { runningTool = nil }
      // A PermissionRequest has no tool_use_id, so its tool and input pair it
      // with the call that finished. A prompt known only from a Notification
      // has no tool, so any finished call clears it.
      if let open = openPermission,
        open.tool == Attention.notificationPromptTool || (open.tool == tool && open.input == d["tool_input"])
      {
        openPermission = nil
      }
    case "Notification":
      switch d["notification_type"]?.string ?? "" {
      case "permission_prompt", "elicitation_dialog":
        // A prompt that no PermissionRequest reported, such as one from a hook
        // that failed.
        if openPermission == nil && openQuestion == nil && turnRunning {
          openPermission = ToolCall(
            tool: Attention.notificationPromptTool, summary: d["message"]?.string ?? "a prompt", since: event.t)
        }
      case "idle_prompt":
        // Claude Code reports the idle prompt 60 s after a Stop. It sends none
        // after Escape.
        endTurn()
      default:
        break
      }
    case "Stop":
      endTurn()
      lastReply = d["last_assistant_message"]?.string
    case "StopFailure", "idle":
      // An API or usage limit error ends the turn without a Stop. So does
      // Escape, which sbd finds out from `claude agents` and records as idle.
      endTurn()
    case "SubagentStart":
      if let id = d["agent_id"]?.string { subagents.insert(id) }
    case "SubagentStop":
      if let id = d["agent_id"]?.string { subagents.remove(id) }
    case "pr":
      pr = d["pr"].flatMap { try? JSONCoding.convert($0, to: PullRequest.self) }
      if pr?.ready == true { readySince = readySince ?? event.t } else { readySince = nil }
      // A pr event carries the comments only when they changed. An event
      // without a PR clears them.
      if let comments = d["comments"] {
        prComments = (try? JSONCoding.convert(comments, to: [PRComment].self)) ?? []
      } else if pr == nil {
        prComments = []
      }
    case "worktree":
      dirty = d["dirty"]?.int
      folderGone = d["gone"]?.bool ?? false
      cleanupChecked = d["cleanup"].map { CleanupStatus(blocker: $0.string) }
    case "cleanup":
      let kept = d["branch_removed"]?.bool == false ? d["branch"]?.string : nil
      cleanedUp = CleanupStatus(state: .removed, reason: kept.map { "kept \($0)" })
    case "dependencies":
      dependencies = d["dependencies"].flatMap { try? JSONCoding.convert($0, to: [Dependency].self) } ?? []
    case "merge":
      merge = try? JSONCoding.convert(event.data, to: MergeAttempt.self)
    case ReviewRequestAttempt.event:
      reviewRequest = try? JSONCoding.convert(event.data, to: ReviewRequestAttempt.self)
    default:
      break
    }
    applyCards(event, userPrompt: userPrompt)
    applyTriage(event)
    applyAutoContinue(event, userPrompt: userPrompt)
  }

  private mutating func startTurn(_ t: Int64) {
    if !turnRunning {
      turnRunning = true
      turnStarted = t
    }
  }

  mutating func endTurn() {
    turnRunning = false
    turnStarted = nil
    runningTool = nil
    openPermission = nil
    openQuestion = nil
  }
}

/// What decided a verdict.
public enum VerdictSource: Equatable, Sendable {
  /// The session's last reply.
  case reply
  /// Any other rule.
  case rule
}

/// The state and its reason line. `kind` is the triage kind of the item that
/// a rule verdict becomes, and `source` tells a reply verdict from a rule
/// verdict. Two verdicts are equal when their state and reason are.
public struct Verdict: Equatable, Sendable {
  public var state: AttentionState
  public var reason: String
  public var kind: TriageKind = .action
  public var source: VerdictSource = .rule
  /// What the session's card offers for a rule that knows the next step.
  public var options: [TriageOption] = []
  /// What the user should read before deciding.
  public var callouts: [Callout] = []
  /// The card's summary for a rule that has more to say than its reason.
  public var summary: String?

  public static func == (a: Verdict, b: Verdict) -> Bool { a.state == b.state && a.reason == b.reason }
}

public enum ReplyKind: Equatable, Sendable {
  /// A question that only the user can answer.
  case question(String)
  /// A next step that needs no decision, such as "Want me to push?".
  case offer(String)
  case other

  var isQuestion: Bool {
    if case .question = self { return true }
    return false
  }
}

/// The attention rules. They follow the `/sessions` skill
/// (`~/.dotfiles/ai/skills/sessions/SKILL.md`) for the facts that hooks, sb,
/// and the GitHub poller provide. Their only CI rule is a failed Depot job, and
/// they have no rule for a PR that Trunk's queue holds.
public enum Attention {
  static let notificationPromptTool = "prompt"
  static let dayMs: Int64 = 24 * 3600 * 1000
  public static let staleAfterMs: Int64 = 2 * dayMs
  /// A subagent with no event for this long is taken to have lost its
  /// SubagentStop, as when sbd was down.
  public static let subagentQuietMs: Int64 = 30 * 60 * 1000

  /// `stateOf` gives another session's last state, which the dependency
  /// rules read for the session of a stack base.
  public static func evaluate(
    _ session: Session, _ facts: SessionFacts, now: Int64, stateOf: (String) -> AttentionState? = { _ in nil }
  ) -> Verdict {
    let verdict = rules(session, facts, now: now, stateOf: stateOf)
    return readyForReview(verdict, facts) ?? verdict
  }

  static func rules(
    _ session: Session, _ facts: SessionFacts, now: Int64, stateOf: (String) -> AttentionState?
  ) -> Verdict {
    if session.done { return Verdict(state: .done, reason: "marked done") }
    if let verdict = followupVerdict(session) { return verdict }
    if let verdict = docketVerdict(session, facts) { return verdict }
    if let card = facts.cards.first {
      return Verdict(state: .needsYou, reason: oneLine(card.reason))
    }
    if let p = facts.openPermission {
      return Verdict(state: .needsYou, reason: oneLine("approve \(p.summary)"))
    }
    if let q = facts.openQuestion {
      return Verdict(state: .needsYou, reason: oneLine("answer: \(q.summary)"))
    }
    if let v = finishedPR(session, facts) { return v }
    if facts.turnRunning {
      if let tool = facts.runningTool {
        return Verdict(state: .working, reason: oneLine("\(tool.summary) (\(minutes(now - tool.since)))"))
      }
      return Verdict(state: .working, reason: "working (\(minutes(now - (facts.turnStarted ?? now))))")
    }
    if let verdict = waitVerdict(session, facts) { return verdict }
    if facts.prompts == 0 && facts.lastReply == nil {
      return Verdict(state: .needsYou, reason: "give it a first prompt")
    }
    if let v = blockedPR(facts, stateOf: stateOf) { return v }
    if let v = openPR(facts) { return v }
    if let v = awaitingReview(facts) { return v }
    if let v = heldPR(facts) { return v }
    if now - facts.lastActivity > staleAfterMs, !needsPRAction(facts) {
      return Verdict(state: .stale, reason: "idle for \((now - facts.lastActivity) / dayMs) days")
    }
    if !facts.subagents.isEmpty, now - facts.lastActivity <= subagentQuietMs,
      case .other = classify(facts.lastReply ?? "")
    {
      let n = facts.subagents.count
      return Verdict(state: .waiting, reason: "waiting on \(n) subagent\(n == 1 ? "" : "s")")
    }
    // A question still needs the user's answer while a job runs.
    if facts.jobs > 0, !classify(facts.lastReply ?? "").isQuestion {
      return Verdict(
        state: .waiting, reason: "waiting on \(facts.jobs) background job\(facts.jobs == 1 ? "" : "s")")
    }
    if let v = unreviewedPR(facts) { return v }
    return replyVerdict(facts.lastReply ?? "")
  }

  /// Evaluates the session at `now`, and records in `facts` when its state
  /// changed. sbd calls it after each event, with the event's time, and on
  /// each tick, for the states that time alone changes.
  @discardableResult
  public static func track(
    _ session: Session, _ facts: inout SessionFacts, now: Int64, stateOf: (String) -> AttentionState? = { _ in nil }
  ) -> Verdict {
    let verdict = evaluate(session, facts, now: now, stateOf: stateOf)
    if verdict.state != facts.lastState {
      facts.lastState = verdict.state
      facts.stateSince = now
    }
    return verdict
  }

  static let offerStarts = [
    "want me to", "should i", "shall i", "would you like me to", "do you want me to", "should we",
    "shall we", "ready for me to", "ok to", "okay to", "want to",
  ]
  static let nextStepPhrases = ["next, i'll", "next i'll", "i'll now", "the next step is", "next step:"]

  /// Classifies a reply by the last question in its last paragraph, or by a
  /// next step that the paragraph announces.
  public static func classify(_ reply: String) -> ReplyKind {
    let paragraphs = reply.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard let last = paragraphs.last else { return .other }
    let parts = sentences(last)
    if let q = parts.last(where: { $0.hasSuffix("?") }) {
      let lower = q.lowercased()
      return offerStarts.contains(where: { lower.hasPrefix($0) }) ? .offer(q) : .question(q)
    }
    if let s = parts.first(where: { s in nextStepPhrases.contains { s.lowercased().contains($0) } }) {
      return .offer(s)
    }
    return .other
  }

  static let sentenceClosers: Set<Character> = ["*", "_", "`", "\"", "'", "\u{201D}", "\u{2019}", ")", "]"]

  static func sentences(_ text: String) -> [String] {
    var out: [String] = []
    var current = ""
    let chars = Array(text)
    for (i, ch) in chars.enumerated() {
      current.append(ch == "\n" ? " " : ch)
      guard ch == "?" || ch == "." || ch == "!" else { continue }
      // A mark inside a name such as README.md or v1.2.3 does not end a sentence.
      // Closing markdown and quotes after the mark stay with the sentence.
      var j = i + 1
      while j < chars.count, sentenceClosers.contains(chars[j]) || (ch == "?" && chars[j] == "!") { j += 1 }
      if j == chars.count || chars[j].isWhitespace {
        out.append(current)
        current = ""
      }
    }
    out.append(current)
    return out.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*_` -").union(.whitespaces)) }.filter {
      !$0.isEmpty
    }
  }

  /// A subagent's result arrives as a prompt. On Claude Code 2.1.308 it is a
  /// <task-notification> block. On 2.1.310 it is an <agent-message> block.
  public static func isSubagentResult(_ prompt: String) -> Bool {
    prompt.hasPrefix("<task-notification>") || prompt.hasPrefix("<agent-message ")
  }

  static func call(_ tool: String, _ d: JSON, _ t: Int64) -> ToolCall {
    let input = d["tool_input"]
    let summary =
      tool == "AskUserQuestion"
      ? (input?["questions"]?.array?.first?["question"]?.string ?? "a question") : toolSummary(tool, input)
    return ToolCall(tool: tool, summary: summary, since: t, id: d["tool_use_id"]?.string, input: input)
  }

  /// Whether a finished call is this one: by tool_use_id, or by tool name
  /// when either side has no id.
  static func same(_ call: ToolCall, _ tool: String, _ id: String?) -> Bool {
    if let a = call.id, let b = id { return a == b }
    return call.tool == tool
  }

  public static func toolSummary(_ tool: String, _ input: JSON?) -> String {
    switch tool {
    case "Bash":
      return "`\(oneLine(input?["command"]?.string ?? "a command", max: 50))`"
    case "Edit", "Write", "Read", "NotebookEdit":
      let path = input?["file_path"]?.string ?? input?["notebook_path"]?.string ?? ""
      return "\(tool) \((path as NSString).lastPathComponent)"
    case "Agent", "Task":
      return "a subagent: \(oneLine(input?["description"]?.string ?? "", max: 40))"
    default:
      if tool.hasPrefix("mcp__") {
        return tool.split(separator: "_", omittingEmptySubsequences: true).dropFirst().joined(separator: " ")
      }
      return tool
    }
  }

  static func minutes(_ ms: Int64) -> String {
    let m = max(0, ms) / 60_000
    return m < 1 ? "<1 min" : "\(m) min"
  }
}
