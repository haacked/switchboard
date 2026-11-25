import Foundation

/// A main-session turn that ended in a StopFailure. It stays until the next main-session prompt or Stop.
public struct TurnFailure: Codable, Equatable, Sendable {
  /// The StopFailure's `error`, such as `authentication_failed` or `rate_limit`.
  public var error: String
  /// The StopFailure's `last_assistant_message`, which Claude Code shows in the pane.
  public var message: String?
  /// The key of the account that claude ran under, which sbd adds to the event. An event that an older sbd
  /// recorded has none.
  public var account: String?
  public var at: Int64

  public static let authenticationFailed = "authentication_failed"

  /// Whether claude's login failed, so the turn can go on only once the login works.
  public var isLogin: Bool { error == Self.authenticationFailed }

  /// The account's short name. A host's key names the host.
  public static func accountName(_ key: String) -> String {
    Account.host(ofKey: key) ?? Account.name(ofFolder: key)
  }

  /// Whether two account keys name the same account, however each folder is written.
  public static func sameAccount(_ a: String, _ b: String) -> Bool {
    func normal(_ key: String) -> String { Account.host(ofKey: key) == nil ? ClaudeAccount.normalize(key) : key }
    return normal(a) == normal(b)
  }
}

extension SessionFacts {
  /// The reply that the app shows: the message of an open login failure, else `lastReply`.
  public var shownReply: String? {
    guard let failure = turnFailure, failure.isLogin, let message = failure.message, !message.isEmpty else {
      return lastReply
    }
    return message
  }

  /// A subagent's StopFailure leaves the main turn running, so only the main session's counts.
  mutating func applyTurnFailure(_ event: Event) {
    let d = event.data
    switch event.kind {
    case "StopFailure" where !event.fromSubagent:
      turnFailure = Box(
        TurnFailure(
          error: d["error"]?.string ?? "unknown", message: d["last_assistant_message"]?.string,
          account: d["account"]?.string, at: event.t))
    case "UserPromptSubmit" where !event.fromSubagent, "Stop" where !event.fromSubagent, OperatorReset.event:
      turnFailure = nil
    case LoginResume.eventKind:
      loginResumes = loginResumes.filter { event.t - $0 < AutoContinue.hourMs } + [event.t]
      if d["delivery"] != nil { loginResumeSent = event.t }
    default:
      break
    }
  }
}

extension Attention {
  /// Needs you for a turn that stopped because claude's login failed. The reason holds no time, because an
  /// acknowledgment and `Verdict ==` compare reasons.
  static func loginFailureVerdict(_ facts: SessionFacts) -> Verdict? {
    guard let failure = facts.turnFailure, failure.isLogin else { return nil }
    let login = failure.account.map { "its Claude login for \(TurnFailure.accountName($0))" } ?? "its Claude login"
    var verdict = Verdict(state: .needsYou, reason: "\(login) expired; run /login")
    let said = failure.message.map { "Claude stopped the turn with \u{201C}\($0)\u{201D}. " } ?? ""
    // A host's login and a failure with no account give sbd no sign that the login works again.
    let resumes = failure.account.map { Account.host(ofKey: $0) == nil } ?? false
    let next =
      resumes
      ? "Run /login in the session. Switchboard continues the turn once the login works again."
      : "Run /login in the session, then send it a message to continue the turn."
    verdict.summary = "\(said)\(next)"
    verdict.loginFailed = true
    return verdict
  }
}

/// What `LoginResume.blocker` decides from.
public struct LoginResumeInput {
  public var session: Session
  public var facts: SessionFacts
  public var now: Int64
  public var process = PromptGuard.Process.running
  /// A message is in flight or queued for the session.
  public var busy = false
  /// Sessions whose claude runs or is starting, this one included.
  public var live = 0
  public var liveCap = 12
  /// The key of the account that the session's claude runs under now.
  public var account = ""
  /// Whether sbd read the failed account's usage without an error after the failure.
  public var loginWorks = false

  public init(session: Session, facts: SessionFacts, now: Int64) {
    self.session = session
    self.facts = facts
    self.now = now
  }
}

/// sbd continues a turn that stopped on a failed login once the login works again: the session moved to another
/// account, or the failed account's usage read succeeds.
public enum LoginResume {
  public static let eventKind = "login-resume"
  /// A login that still fails would fail each continue again. This many continues an hour bounds that loop.
  public static let perHour = 3
  public static let message =
    "Switchboard: Your previous turn stopped because the Claude login expired. The login works again. Continue where you left off."

  /// The first reason that holds back the continue, or nil when nothing does.
  public static func blocker(_ input: LoginResumeInput) -> String? {
    let f = input.facts
    guard let failure = f.turnFailure, failure.isLogin else { return "no failed login" }
    // An event that an older sbd recorded names no account, so nothing shows when the login works again.
    guard let failed = failure.account else { return "the failure names no account" }
    // A send that failed leaves the failure open for the next tick, within the hourly cap below.
    if let sent = f.loginResumeSent, sent >= failure.at { return "already continued" }
    if input.session.done { return "marked done" }
    if let pause = Pause.blocker(input.session) { return pause }
    if input.session.removal?.holdsSession == true { return "being removed" }
    if let card = PromptGuard.openCard(f) { return card }
    if let turn = PromptGuard.turn(f, process: input.process, messageWaiting: input.busy) { return turn }
    if TurnFailure.sameAccount(input.account, failed), !input.loginWorks {
      return "its Claude login for \(TurnFailure.accountName(failed)) still fails"
    }
    let recent = f.loginResumes.filter { input.now - $0 < AutoContinue.hourMs }.count
    if recent >= perHour { return "continued \(recent) times after a failed login in the last hour" }
    if input.process == .stopped, input.live >= input.liveCap { return "the live cap of \(input.liveCap) is full" }
    return nil
  }
}
