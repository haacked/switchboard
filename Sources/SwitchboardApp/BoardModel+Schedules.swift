import SwitchboardCore

/// The log of one run of a headless or script loop, as the Output sheet shows it.
struct LoopOutput: Equatable {
  let schedule: String
  /// 1 is the newest run.
  let run: Int
  /// The time of the run whose log `text` holds, which names the log. sbd's answer sets it, because a run that lands
  /// before sbd reads the log changes which run `run` counts to.
  var t: Int64?
  /// The log, or nil until sbd answers.
  var text: String?
  /// The lines of `text`, each control character shown as an escape. The app escapes sbd's answer once, off the main
  /// thread. A newline at the end starts no line.
  var lines: [String] = []
  /// The run's output passed the log's cap.
  var truncated = false
  /// sbd's refusal, such as a loop that has not run yet.
  var error: String?

  /// The run whose log the sheet shows, or nil when `history` no longer keeps it.
  func shownRun(in history: [Schedule.Run]) -> Schedule.Run? {
    t.flatMap { t in history.first { $0.t == t } }
  }

  static func printableLines(_ text: String) -> [String] {
    var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    if lines.last?.isEmpty == true { lines.removeLast() }
    return lines.map(\.printable)
  }
}

extension BoardModel {
  func pauseSchedule(_ id: String, paused: Bool) {
    perform("pause-schedule", ["schedule": .string(id), "paused": .bool(paused)])
  }

  /// sbd makes the schedule due and sends nothing itself. Its tick runs the schedule once the session is free.
  func runSchedule(_ id: String) {
    perform("run-schedule", ["schedule": .string(id)])
  }

  /// The loop editor closes when sbd adds the loop. A refusal leaves it open, with the reason in `loopEditorError`.
  /// `session` is a session id, or `Manager.operatorName`, for which sbd creates the operator when it has none. A
  /// script's command travels in `prompt`. A nil account, model, or timeout runs on the session's or the default.
  func addSchedule(
    session: String, every: String, prompt: String, runner: Schedule.Runner = .session, account: String? = nil,
    model: String? = nil, timeout: String? = nil
  ) {
    var args: [String: JSON] = [
      "session": .string(session), "every": .string(every), "prompt": .string(prompt),
      "by": .string(Author.you.rawValue),
    ]
    if runner != .session { args["runner"] = .string(runner.rawValue) }
    args.merge(Self.runOptions(account: account, model: model, timeout: timeout)) { $1 }
    saveLoop("schedule", args)
  }

  /// Sends only the fields that are not nil. An empty account or model resets it to the session's. The loop editor
  /// closes as `addSchedule` describes.
  func editSchedule(
    _ id: String, every: String?, prompt: String?, account: String? = nil, model: String? = nil,
    timeout: String? = nil
  ) {
    var args: [String: JSON] = ["schedule": .string(id)]
    if let every { args["every"] = .string(every) }
    if let prompt { args["prompt"] = .string(prompt) }
    args.merge(Self.runOptions(account: account, model: model, timeout: timeout)) { $1 }
    saveLoop("edit-schedule", args)
  }

  /// The account, the model, and the timeout that are not nil, as an add and an edit send them.
  private static func runOptions(account: String?, model: String?, timeout: String?) -> [String: JSON] {
    var args: [String: JSON] = [:]
    if let account { args["account"] = .string(account) }
    if let model { args["model"] = .string(model) }
    if let timeout { args["timeout"] = .string(timeout) }
    return args
  }

  private func saveLoop(_ op: String, _ args: [String: JSON]) {
    guard !savingLoop else { return }
    let opening = loopEditorOpening
    savingLoop = true
    loopEditorError = nil
    perform(
      op, args,
      then: { _ in if self.loopEditorOpening == opening { self.loopEditor = nil } },
      failed: { error in if self.loopEditorOpening == opening { self.loopEditorError = "\(error)" } },
      finally: { self.savingLoop = false })
  }

  func removeSchedule(_ id: String) {
    perform("remove-schedule", ["schedule": .string(id)])
  }

  /// Opens the Output sheet on the loop's run `run`, 1 for the newest, and reads its log from sbd. A refusal shows
  /// in the sheet. An answer for a run that the sheet no longer shows is dropped.
  func loadScheduleLog(_ id: String, run: Int? = nil) {
    let n = run ?? 1
    let known = schedule(id)?.history
    let shown = LoopOutput(schedule: id, run: n, t: known.flatMap { n <= $0.count ? $0[n - 1].t : nil })
    loopOutput = shown
    var args: [String: JSON] = ["schedule": .string(id)]
    if let run { args["run"] = .number(Double(run)) }
    perform(
      "schedule-log", args,
      then: { answer in
        guard self.loopOutput == shown else { return }
        let text = answer["text"]?.string ?? ""
        Task {
          let lines = await Task.detached { LoopOutput.printableLines(text) }.value
          guard self.loopOutput == shown else { return }
          self.loopOutput?.lines = lines
          self.loopOutput?.text = text
          self.loopOutput?.truncated = answer["truncated"]?.bool == true
          if let t = answer["t"]?.int { self.loopOutput?.t = Int64(t) }
        }
      },
      failed: { error in if self.loopOutput == shown { self.loopOutput?.error = "\(error)" } })
  }
}
