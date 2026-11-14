import Foundation

/// The rule's Inbox item that the user answered with a message, as a
/// `request` event recorded it, and what the session did after it.
public struct InboxRequest: Codable, Equatable, Sendable, SeenVerdict {
  public static let event = "request"

  public var state: AttentionState
  public var reason: String
  public var head: String?
  /// The message that answered the item.
  public var message: String
  /// When the hold ends while work still runs. sbd stamps it from
  /// `recheckSeconds.requested`.
  public var until: Int64
  /// How long the hold waits after a turn ends before a stall ends it, so
  /// that the GitHub poller can read a push that the turn made.
  public var readMs: Int64
  /// When the `request` event was recorded. The event's time sets it, so the
  /// event's data leaves it out.
  public var at: Int64?
  /// When the last turn after the request ended.
  public var ended: Int64?
  /// When a turn that a background result started ended without starting new
  /// background work. The session had what it waited on and stopped.
  public var stalled: Int64?
  /// Whether the current turn got a background result.
  public var resultInTurn: Bool?
  /// Whether the current turn started a background job, a background
  /// subagent, or a Monitor.
  public var launchedInTurn: Bool?

  public init(_ verdict: Verdict, _ facts: SessionFacts, message: String, until: Int64, readMs: Int64) {
    state = verdict.state
    reason = verdict.reason
    head = facts.pr?.headSha
    self.message = message
    self.until = until
    self.readMs = readMs
  }
}

extension SessionFacts {
  /// Folds the request and the turns after it. `turnEnded` is true when the
  /// event ended a running turn. A turn that got a background result and
  /// started no background work marks the request stalled. A prompt from the
  /// user other than the request's message clears the request, because the
  /// user then asked for something else.
  mutating func applyRequest(_ event: Event, userPrompt: Bool, turnEnded: Bool) {
    switch event.kind {
    case InboxRequest.event:
      request = try? JSONCoding.convert(event.data, to: InboxRequest.self)
      request?.at = event.t
    case "unack":
      request = nil
    case "UserPromptSubmit":
      let prompt = event.data["prompt"]?.string ?? ""
      if userPrompt, prompt != request?.message { request = nil }
      if Attention.isSubagentResult(prompt) { request?.resultInTurn = true }
    case "PreToolUse" where !event.fromSubagent:
      let tool = event.data["tool_name"]?.string
      if tool == "Monitor" || event.data["tool_input"]?["run_in_background"]?.bool == true {
        request?.launchedInTurn = true
      }
    default:
      break
    }
    guard turnEnded, var r = request else { return }
    r.ended = event.t
    if r.resultInTurn == true, r.launchedInTurn != true { r.stalled = r.stalled ?? event.t }
    r.resultInTurn = nil
    r.launchedInTurn = nil
    request = r
  }
}

extension Attention {
  /// The verdict while the session works on the user's request. A rule
  /// verdict that the request covers moves to Waiting until the session
  /// stalls, asks a question, or passes the request's `until`. A stall is a
  /// turn that got a background result and started no background work, or a
  /// turn end with no job or subagent left. A stall counts only `readMs`
  /// after its turn ended, because the poller may not have read a push yet.
  /// When the hold ends, the rule's reason says why. Unlike an
  /// acknowledgment, the hold is part of `evaluate`, so parent notices and
  /// every other rule of sbd's see Waiting while it lasts.
  static func requested(_ verdict: Verdict, _ facts: SessionFacts, now: Int64) -> Verdict {
    guard verdict.source == .rule, let request = facts.request, request.covers(verdict, facts) else { return verdict }
    let asked = "you asked at \(Wait.formatTime(request.at ?? now))"
    func line(_ text: String) -> String { oneLine(text, max: 200) }
    func released(_ why: String) -> Verdict {
      var out = verdict
      out.reason = line("\(verdict.reason) (\(asked); \(why))")
      return out
    }
    func work() -> String {
      guard request.ended != nil else { return "waiting for it to start" }
      if request.stalled == nil, facts.jobs > 0 {
        return "\(facts.jobs) background job\(facts.jobs == 1 ? "" : "s") running"
      }
      if request.stalled == nil, facts.subagentsRunning(now: now) {
        return "\(facts.subagents.count) subagent\(facts.subagents.count == 1 ? "" : "s") running"
      }
      return "waiting for GitHub to read the PR"
    }
    if now >= request.until { return released("time to recheck") }
    if let ended = request.ended {
      if classify(facts.lastReply ?? "").isQuestion { return released("it asked a question") }
      let idle = !facts.jobsRunning(now: now) && !facts.subagentsRunning(now: now)
      if let since = request.stalled ?? (idle ? ended : nil), now >= since + request.readMs {
        return released("the session stopped without doing it")
      }
    }
    return Verdict(state: .waiting, reason: line("\(asked): \(verdict.reason); \(work())"), requested: true)
  }
}
