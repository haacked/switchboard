import Foundation

/// A script schedule that a session asked for, which waits for the user to approve or deny it. A script runs on a
/// timer with no permission prompt, so only the user approves one. sbd records the proposal once, in the
/// `script_proposed` event that opens its card, and an approval reads the values from there.
public struct ScriptProposal: Codable, Equatable, Sendable {
  /// What an edit's schedule held when the card opened. An approval refuses as stale when the schedule holds
  /// something else by then.
  public struct Before: Codable, Equatable, Sendable {
    public var command: String
    public var timeout: Int64?
    /// The interval, when the edit changes it. Without it, the schedule's interval was `every`.
    public var every: Int64?

    public init(command: String, timeout: Int64?, every: Int64? = nil) {
      self.command = command
      self.timeout = timeout
      self.every = every
    }
  }

  /// How long a proposal waits for the user's decision before it expires.
  public static let expirySeconds: Int64 = 86_400
  /// The most characters a proposed command holds, because the card shows the whole command.
  public static let maxCommand = 2_000
  /// What the card tells the user about a command that runs a file in the session's folder.
  public static let worktreeNote =
    "A command that runs a file in the session's folder, such as bin/sync, make, or npm run, runs code that the session's Claude can edit."

  /// The session that the schedule runs on, by id.
  public var target: String
  public var targetName: String
  /// The target's folder, where the command runs.
  public var folder: String
  /// The interval in ms.
  public var every: Int64
  /// The command exactly as sbd would store it. The app shows it and never interprets it.
  public var command: String
  /// The timeout in ms, or nil for the default.
  public var timeout: Int64?
  /// Why the session asks, exactly as Claude wrote it.
  public var reason: String
  /// The schedule that an edit changes, or nil for a new schedule.
  public var schedule: String?
  public var before: Before?
  /// Milliseconds since the epoch.
  public var expires: Int64

  public init(
    target: String, targetName: String, folder: String, every: Int64, command: String, timeout: Int64?,
    reason: String, schedule: String? = nil, before: Before? = nil, expires: Int64
  ) {
    self.target = target
    self.targetName = targetName
    self.folder = folder
    self.every = every
    self.command = command
    self.timeout = timeout
    self.reason = reason
    self.schedule = schedule
    self.before = before
    self.expires = expires
  }

  /// The command on one line, with each control character shown as an escape, for a title or an attention line.
  public var line: String {
    oneLine(command.replacingOccurrences(of: "\t", with: " ")).printable
  }

  /// The interval and the timeout, such as `every 1h · timeout 10m (default)`.
  public var timingText: String {
    let limit =
      timeout.map(Schedule.intervalText)
      ?? "\(Schedule.intervalText(Schedule.defaultTimeout(.script, every: every))) (default)"
    return "every \(Schedule.intervalText(every)) · timeout \(limit)"
  }
}

/// What became of a script proposal.
public enum ScriptDecision: String, Codable, Sendable {
  case pending
  case approved
  case denied
  case expired
  /// The schedule that an edit's card changes no longer holds what the card showed, or is gone.
  case stale
}

/// sbd's answer to a proposal, to `schedule-pending`, and to an answer of a `script` card.
public struct ScriptProposalStatus: Codable, Equatable, Sendable {
  /// The card's id.
  public var pending: Int64
  public var decision: ScriptDecision
  /// The schedule that an approval stored or changed.
  public var schedule: String?

  public init(pending: Int64, decision: ScriptDecision, schedule: String? = nil) {
    self.pending = pending
    self.decision = decision
    self.schedule = schedule
  }
}

extension Card {
  /// The card that a `script_proposed` event opens, or nil when its data isn't a proposal.
  public init?(scriptProposal event: Event) {
    guard let proposal = try? JSONCoding.convert(event.data, to: ScriptProposal.self) else { return nil }
    id = event.id
    session = event.session
    kind = .script
    tool = "propose_script"
    summary = proposal.line
    input = [:]
    questions = []
    since = event.t
    deferred = false
    hookClosed = false
    scriptProposal = Box(proposal)
  }
}

extension Client {
  /// Asks sbd about the proposal every 0.5 s until the user decides or `timeout` seconds pass, and returns the last
  /// status.
  public func awaitScriptProposal(_ id: Int64, timeout: TimeInterval) throws -> ScriptProposalStatus {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      let status = try call("schedule-pending", ["card": .number(Double(id))], as: ScriptProposalStatus.self)
      if status.decision != .pending || Date() >= deadline { return status }
      Thread.sleep(forTimeInterval: 0.5)
    }
  }
}
