import Foundation

/// A tool call that the main session waits on: a running tool, a permission
/// prompt, or a question.
public struct ToolCall: Equatable, Sendable {
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
public struct SessionFacts: Equatable, Sendable {
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

  public init() {}

  public mutating func apply(_ event: Event) {
    let d = event.data
    // The poller's events report on GitHub and the folder, not on the
    // session, so they don't hold off the idle stop or the Stale state.
    if event.kind != "pr" && event.kind != "worktree" { lastActivity = max(lastActivity, event.t) }
    let userPrompt = isUserPrompt(event)
    applyWait(event, userPrompt: userPrompt)
    // A subagent's tool calls don't change what the main session waits on.
    let fromSubagent = event.fromSubagent
    let tool = d["tool_name"]?.string ?? ""
    switch event.kind {
    case "SessionStart":
      live = true
      lastStart = event.t
      transcriptPath = d["transcript_path"]?.string
    case "running":
      live = true
    case "started", "resumed":
      lastLaunch = event.t
    case "imported":
      // The transcript's last line, not the import, is the session's last activity.
      if let t = d["lastActivity"]?.int { lastActivity = Int64(t) }
      lastReply = d["lastReply"]?.string
      // A reply means that the user sent a prompt before it.
      if d["hasReplies"]?.bool == true { prompts = max(prompts, 1) }
    case "SessionEnd", "stopped", "exited":
      live = false
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
      // with the call that finished.
      if let open = openPermission, open.tool == tool, open.input == d["tool_input"] { openPermission = nil }
    case "Notification":
      switch d["notification_type"]?.string ?? "" {
      case "permission_prompt", "elicitation_dialog":
        // A prompt that no PermissionRequest reported, such as one from a hook
        // that failed.
        if openPermission == nil && openQuestion == nil && turnRunning {
          openPermission = ToolCall(tool: "prompt", summary: d["message"]?.string ?? "a prompt", since: event.t)
        }
      case "idle_prompt":
        // A turn that the user interrupted with Escape or No ends without a
        // Stop. Claude Code reports the idle prompt 60 s later.
        endTurn()
      default:
        break
      }
    case "Stop":
      endTurn()
      lastReply = d["last_assistant_message"]?.string
    case "StopFailure":
      // An API or usage limit error ends the turn without a Stop.
      endTurn()
    case "SubagentStart":
      if let id = d["agent_id"]?.string { subagents.insert(id) }
    case "SubagentStop":
      if let id = d["agent_id"]?.string { subagents.remove(id) }
    case "pr":
      pr = d["pr"].flatMap { try? JSONCoding.convert($0, to: PullRequest.self) }
      prComments = d["comments"].flatMap { try? JSONCoding.convert($0, to: [PRComment].self) } ?? []
    case "worktree":
      dirty = d["dirty"]?.int
    default:
      break
    }
    applyCards(event, userPrompt: userPrompt)
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

/// The state and its reason line.
public struct Verdict: Equatable, Sendable {
  public var state: AttentionState
  public var reason: String
}

public enum ReplyKind: Equatable, Sendable {
  /// A question that only the user can answer.
  case question(String)
  /// A next step that needs no decision, such as "Want me to push?".
  case offer(String)
  case other
}

/// The attention rules. They follow the `/sessions` skill
/// (`~/.dotfiles/ai/skills/sessions/SKILL.md`) for the facts that hooks, sb,
/// and the GitHub poller provide. They have no CI rules, and no rule for a PR
/// that Trunk's queue holds.
public enum Attention {
  static let dayMs: Int64 = 24 * 3600 * 1000
  public static let staleAfterMs: Int64 = 2 * dayMs

  public static func evaluate(_ session: Session, _ facts: SessionFacts, now: Int64) -> Verdict {
    if session.done { return Verdict(state: .done, reason: "marked done") }
    if let verdict = followupVerdict(session) { return verdict }
    if let card = facts.cards.first {
      let reason = card.kind == .permission ? "approve \(card.summary)" : "answer: \(card.summary)"
      return Verdict(state: .needsYou, reason: oneLine(reason))
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
    if let v = openPR(facts) { return v }
    if now - facts.lastActivity > staleAfterMs {
      return Verdict(state: .stale, reason: "idle for \((now - facts.lastActivity) / dayMs) days")
    }
    switch classify(facts.lastReply ?? "") {
    case .question(let q): return Verdict(state: .needsYou, reason: oneLine("answer: \(q)"))
    case .offer(let o): return Verdict(state: .canContinue, reason: oneLine("offered: \(o)"))
    case .other: return Verdict(state: .needsYou, reason: "read its last reply and decide what's next")
    }
  }

  /// Evaluates the session at `now`, and records in `facts` when its state
  /// changed. sbd calls it after each event, with the event's time, and on
  /// each tick, for the states that time alone changes.
  @discardableResult
  public static func track(_ session: Session, _ facts: inout SessionFacts, now: Int64) -> Verdict {
    let verdict = evaluate(session, facts, now: now)
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

  static func sentences(_ text: String) -> [String] {
    var out: [String] = []
    var current = ""
    for ch in text {
      current.append(ch == "\n" ? " " : ch)
      if ch == "?" || ch == "." || ch == "!" {
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
