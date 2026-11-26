import Foundation
import SwitchboardCore

/// One-shot `claude -p` turns that sbd runs for itself, such as the triage
/// summary and the plan update.
extension Service {
  /// The environment of a turn under a Claude account. With `session`, the
  /// turn takes the session's pane environment and account. Without one, it
  /// takes `config.env`. `account` overrides either. The turn is not a
  /// session, so it gets no session id. `base` is sbd's own environment.
  /// Callers pick `account` with `headlessAccount(of:)` or `triageAccount(for:)`. A turn whose account would
  /// still be a Codex folder runs under `headlessStandIn`, because claude would write Claude files into the
  /// Codex folder. It reads the state, so the caller must be on the state queue.
  func headlessEnv(
    session: String?, account: ClaudeAccount?, base: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var env = base
    if let session {
      let pane = paneEnv(session)
      env.merge(pane) { $1 }
      // A pane of the default account has no CLAUDE_CONFIG_DIR, and sbd's own value must not stand in for it.
      if entries[session]?.session.host == nil, pane["CLAUDE_CONFIG_DIR"] == nil { env["CLAUDE_CONFIG_DIR"] = nil }
    } else {
      for (key, value) in config.env { env[key] = value.expandingTilde }
      env["SB_HOME"] = home.path
    }
    env["SB_SESSION_ID"] = nil
    account?.apply(to: &env)
    if let folder = env["CLAUDE_CONFIG_DIR"], codexName(folder) != nil { headlessStandIn.apply(to: &env) }
    return env
  }

  /// Runs `claude` with the arguments and the input on stdin, in the folder,
  /// ends it after `timeout` seconds or once `cancelled` returns true, and
  /// parses what it printed. `onLine` can refuse a line of stdout, as
  /// `Headless.run` describes. Every one-shot call that sbd makes runs through
  /// it, and it stores one `headless_calls` row for each call that started
  /// claude: the model and the tokens that claude's envelope reports, and
  /// the error when the call gave no answer that `parse` accepts. Runs off
  /// the state queue.
  func headlessCall<T>(
    _ kind: HeadlessKind, session: String?, arguments: [String], input: String, env: [String: String],
    folder: String, timeout: Double, cancelled: @escaping @Sendable () -> Bool = { false },
    onLine: ((String) -> String?)? = nil, parse: (String) throws -> T
  ) -> HeadlessOutcome<T> {
    let outcome: HeadlessOutcome<T>
    do {
      guard let claude = findExecutable(config.claude) else {
        throw Headless.NotStarted(reason: "can't find \(config.claude)")
      }
      let reply = Headless.reply(
        try Headless.run(
          claude: claude, arguments: arguments, input: input, env: env, folder: folder, timeout: timeout,
          cancelled: cancelled, onLine: onLine))
      outcome = HeadlessOutcome(reply: reply, result: Result { try parse(reply.output) })
    } catch let exit as Headless.ExitError {
      outcome = HeadlessOutcome(reply: Headless.reply(exit.output), result: .failure(exit))
    } catch let refused as Headless.Refused {
      outcome = HeadlessOutcome(reply: Headless.reply(refused.output), result: .failure(refused))
    } catch let notStarted as Headless.NotStarted {
      return HeadlessOutcome(reply: nil, result: .failure(notStarted))
    } catch {
      outcome = HeadlessOutcome(reply: nil, result: .failure(error))
    }
    let (reply, error) = (outcome.reply, outcome.error.map { "\($0)" })
    queue.async { [self] in storeHeadlessCall(kind, session: session, reply: reply, error: error) }
    return outcome
  }

  /// Stores the `headless_calls` row of one call that started claude: the model and the tokens that claude's
  /// envelope reports, and the error when the call gave no answer. It runs on the state queue.
  func storeHeadlessCall(_ kind: HeadlessKind, session: String?, reply: HeadlessReply?, error: String?) {
    let call = HeadlessCall(
      t: nowMs(), kind: kind.rawValue, session: session, model: reply?.model, usage: reply?.usage, error: error)
    do { try store.append(headlessCall: call) } catch { logLine("can't store the \(kind.rawValue) call: \(error)") }
  }

  /// The headless calls per day and kind. `durationMs` limits the report to
  /// the calls from that many milliseconds before now onward.
  func headlessUsage(_ args: JSON) throws -> JSON {
    let since = try sinceMs(args)
    let calls = try store.headlessCalls(since: since ?? 0)
    return try JSON(encoding: HeadlessUsageReport.build(calls, since: since, timeZone: .current))
  }
}

/// What `headlessCall` returns: what claude printed, which is nil when claude
/// did not run or when a timeout or a cancel ended it, and what `parse` made
/// of it.
struct HeadlessOutcome<T> {
  var reply: HeadlessReply?
  var result: Result<T, Error>

  var error: Error? {
    if case .failure(let error) = result { return error }
    return nil
  }
}
