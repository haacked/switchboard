import SwitchboardCore

/// The log of one run of a headless or script loop, as the Output sheet shows it.
struct LoopOutput: Equatable {
  let schedule: String
  /// 1 is the newest run.
  let run: Int
  /// The log, or nil until sbd answers.
  var text: String?
  /// The run's output passed the log's cap.
  var truncated = false
  /// sbd's refusal, such as a loop that has not run yet.
  var error: String?
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
    if let account { args["account"] = .string(account) }
    if let model { args["model"] = .string(model) }
    if let timeout { args["timeout"] = .string(timeout) }
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
    if let account { args["account"] = .string(account) }
    if let model { args["model"] = .string(model) }
    if let timeout { args["timeout"] = .string(timeout) }
    saveLoop("edit-schedule", args)
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
    let shown = LoopOutput(schedule: id, run: run ?? 1)
    loopOutput = shown
    var args: [String: JSON] = ["schedule": .string(id)]
    if let run { args["run"] = .number(Double(run)) }
    perform(
      "schedule-log", args,
      then: { answer in
        guard self.loopOutput == shown else { return }
        self.loopOutput?.text = answer["text"]?.string ?? ""
        self.loopOutput?.truncated = answer["truncated"]?.bool == true
      },
      failed: { error in if self.loopOutput == shown { self.loopOutput?.error = "\(error)" } })
  }
}
