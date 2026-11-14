import Foundation

/// The `autoContinue` object of config.json.
public struct AutoContinueSettings: Codable, Equatable, Sendable {
  /// The text that sbd sends.
  public var message = "Yes, go ahead."
  /// How long the session must go untouched before sbd continues it.
  public var quietSeconds = 600
  /// The most automatic continues per session in any hour.
  public var perHour = 3

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = AutoContinueSettings()
    message = try c.decodeIfPresent(String.self, forKey: .message) ?? d.message
    quietSeconds = try c.decodeIfPresent(Int.self, forKey: .quietSeconds) ?? d.quietSeconds
    perHour = try c.decodeIfPresent(Int.self, forKey: .perHour) ?? d.perHour
  }
}

/// What auto-continue needs to know about an account's remaining usage.
public protocol QuotaBudget: Sendable {
  /// Whether the Claude account in the config folder may spend more on an
  /// automatic continue.
  func hasBudget(account: String) -> Bool
}

/// Says yes for every account.
public struct UnlimitedBudget: QuotaBudget {
  public init() {}
  public func hasBudget(account: String) -> Bool { true }
}

/// What `AutoContinue.blocker` decides from.
public struct AutoContinueInput {
  public enum Process: Sendable { case running, starting, stopped }

  public var session: Session
  public var facts: SessionFacts
  public var verdict: Verdict
  public var now: Int64
  public var settings = AutoContinueSettings()
  public var process = Process.running
  /// A message is in flight or queued for the session.
  public var busy = false
  public var onScreen = false
  /// When the user last viewed the session, or 0.
  public var lastViewed: Int64 = 0
  /// Sessions whose claude runs or is starting, this one included.
  public var live = 0
  /// `Config.liveCap`. A continue that has to start claude needs a free slot.
  public var liveCap = 12
  /// The session's Claude config folder.
  public var account = ""
  public var hasBudget = true

  public init(session: Session, facts: SessionFacts, verdict: Verdict, now: Int64) {
    self.session = session
    self.facts = facts
    self.verdict = verdict
    self.now = now
  }
}

/// One session in Claude can continue, and what holds it back.
public struct AutoContinueCandidate: Codable, Equatable, Sendable {
  public var session: String
  public var name: String
  /// The first guard that holds the session back, or nil when the next tick
  /// continues it.
  public var blocker: String?

  public init(session: String, name: String, blocker: String?) {
    self.session = session
    self.name = name
    self.blocker = blocker
  }
}

/// The reply of the `autocontinue` request.
public struct AutoContinueStatus: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var message: String
  public var quietSeconds: Int
  public var perHour: Int
  public var liveCap: Int
  /// Sessions whose claude runs or is starting.
  public var live: Int
  /// The sessions in Claude can continue, oldest first.
  public var sessions: [AutoContinueCandidate]

  public init(
    enabled: Bool, settings: AutoContinueSettings, liveCap: Int, live: Int, sessions: [AutoContinueCandidate]
  ) {
    self.enabled = enabled
    message = settings.message
    quietSeconds = settings.quietSeconds
    perHour = settings.perHour
    self.liveCap = liveCap
    self.live = live
    self.sessions = sessions
  }
}

public enum AutoContinue {
  public static let hourMs: Int64 = 3600 * 1000
  public static let eventKind = "auto-continue"

  /// The first reason that holds the session back from an automatic
  /// continue, or nil when nothing does.
  public static func blocker(_ input: AutoContinueInput) -> String? {
    let f = input.facts
    let s = input.settings
    if input.verdict.state != .canContinue { return "not in Claude can continue" }
    if let label = input.session.kind.label { return label }
    // A continue starts a new turn, which drops the card from `sb summary set`.
    if !f.cards.isEmpty || f.sessionSummary != nil || f.openPermission != nil || f.openQuestion != nil {
      return "an open card"
    }
    // A continue would answer the reply while the user answers its decisions.
    if f.decisionList != nil || Triage.item(f, input.verdict)?.hasDecisionList == true {
      return "decisions to answer"
    }
    if !(input.session.waits ?? []).isEmpty { return "an open wait" }
    if f.turnRunning { return "a turn is running" }
    if input.busy { return "a message is on its way" }
    if input.process == .starting || (input.process == .running && !f.live) { return "claude is starting or stopping" }
    if input.onScreen { return "on screen" }
    let touched = f.lastSeen(viewed: input.lastViewed)
    let quiet = Int64(s.quietSeconds) * 1000
    if touched > 0, input.now - touched < quiet { return "you touched it \((input.now - touched) / 1000) s ago" }
    let recent = f.autoContinues.filter { input.now - $0 < hourMs }.count
    if recent >= s.perHour { return "continued \(recent) times in the last hour" }
    // A continue leaves the state as it was until claude reports its prompt.
    // The in-flight window alone can't stop a second continue.
    if let last = f.autoContinues.last, last >= f.stateSince { return "already continued this offer" }
    if input.process == .stopped, input.live >= input.liveCap { return "the live cap of \(input.liveCap) is full" }
    if !input.hasBudget { return "no quota left for \(input.account)" }
    return nil
  }
}

extension SessionFacts {
  /// Records the user's touches and sbd's automatic continues.
  mutating func applyAutoContinue(_ event: Event, userPrompt: Bool) {
    switch event.kind {
    case "UserPromptSubmit" where userPrompt, "answered":
      lastTouched = event.t
    case "sent" where event.data["by"]?.string != "sbd":
      lastTouched = event.t
    case AutoContinue.eventKind:
      autoContinues = autoContinues.filter { event.t - $0 < AutoContinue.hourMs } + [event.t]
    default:
      break
    }
  }
}
