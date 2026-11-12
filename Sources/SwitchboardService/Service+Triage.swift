import Foundation
import SwitchboardCore

extension Service {
  func triageRequest(_ op: String, _ args: JSON) throws -> Response {
    switch op {
    case "triage":
      return .success(try queue.sync { try JSON(encoding: Triage.order(summaries())) })
    case "choose":
      return handle(try queue.sync { try chooseRequest(args) })
    case "summary-set":
      return .success(try queue.sync { try setSummary(args) })
    default:
      return .success(try reply(args))
    }
  }

  /// Records the card that the session wrote for its current turn. A new
  /// prompt drops it.
  private func setSummary(_ args: JSON) throws -> JSON {
    let id = try lookup(args)
    guard let raw = args["card"] else { throw APIError("summary set needs the card as JSON") }
    let cleaned = try TriageCard.clean(raw, now: nowMs())
    let event = record(id, Triage.sessionEvent, try JSON(encoding: cleaned.card))
    return [
      "session": .string(id), "event": .number(Double(event.id)),
      "options": .number(Double(cleaned.card.options.count)),
      "callouts": .number(Double(cleaned.card.callouts.count)),
      "decisions": .number(Double(cleaned.card.decisions.count)),
      "drafts": .number(Double(cleaned.card.drafts.count)),
      "dropped": .array(cleaned.dropped.map(JSON.string)),
    ]
  }

  /// The request that does what a click on the option does. Each action is a
  /// request that sbd already has, which makes its own checks.
  private func chooseRequest(_ args: JSON) throws -> Request {
    let id = try lookup(args)
    let name = entries[id]!.session.name
    guard let item = summary(id).triage else { throw APIError("\(name) needs nothing from you") }
    guard !item.options.isEmpty else { throw APIError("\(name) offers no options. Send it a message instead") }
    // The caller's `ref` names the item that the user saw.
    if let ref = args["ref"]?.string, ref != item.ref {
      throw APIError("\(name) has a new item since you looked. Look again")
    }
    let option: TriageOption
    if let keys = args["options"]?.array {
      option = Triage.combined(try item.picks(keys.map { $0.string ?? "" }))
    } else {
      guard let key = args["option"]?.string else { throw APIError("name an option, by number or label") }
      option = try item.option(key)
    }
    // Claude Code may not approve its own prompt or act on its own PR.
    if args["insideClaude"]?.bool == true, item.source == .card || option.action.needsClick {
      throw APIError("choose answers a prompt or acts on a PR for you, so it doesn't run inside Claude Code")
    }
    let session = JSON.string(id)
    switch option.action {
    case .send:
      return Request(op: "send", args: ["session": session, "text": .string(option.message ?? option.label)])
    case .reply:
      let text = args["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !text.isEmpty else { throw APIError("\(option.label) needs the text to send") }
      return Request(op: "send", args: ["session": session, "text": .string(text)])
    case .merge:
      return Request(op: "merge", args: ["session": session])
    case .dismiss:
      return Request(op: "merge", args: ["session": session, "dismiss": true])
    case .requestReview:
      let reviewers = ReviewRequests.reviewers(in: args["text"]?.string ?? "")
      guard !reviewers.isEmpty else {
        throw APIError("\(option.label) needs the reviewers. `sb review \(name)` lists the suggested ones")
      }
      return Request(op: "review", args: ["session": session, "reviewers": .array(reviewers.map(JSON.string))])
    case .wait:
      var wait = try option.wait.map { try JSON(encoding: $0).object ?? [:] } ?? [:]
      wait["session"] = session
      return Request(op: "wait", args: .object(wait))
    case .done:
      return Request(op: "done", args: ["session": session])
    case .allow, .deny, .allowAutoMode, .answer:
      guard item.source == .card, let card = entries[id]!.facts.cards.first else {
        throw APIError("\(name) has no prompt to answer")
      }
      var answer: [String: JSON] = ["session": session, "card": .number(Double(card.id))]
      switch option.action {
      case .answer: answer["answers"] = [.string(option.message ?? option.label)]
      case .allowAutoMode:
        answer["behavior"] = "allow"
        answer["autoMode"] = true
      default: answer["behavior"] = .string(option.action.rawValue)
      }
      return Request(op: "answer", args: .object(answer))
    }
  }

  /// The session's last assistant reply from its transcript, which is read
  /// off the state queue, else the one its Stop hook reported.
  private func reply(_ args: JSON) throws -> JSON {
    let (id, findTranscript, machine, hooked) = try queue.sync {
      () -> (String, () -> String?, any Machine, String?) in
      let id = try lookup(args)
      return (id, transcriptFinder(id), self.machine(of: id), entries[id]!.facts.lastReply)
    }
    let text = findTranscript().flatMap { Transcript.tail($0, on: machine).lastReply }
    guard let reply = text ?? hooked else { throw APIError("\(id) has no reply yet") }
    return ["session": .string(id), "reply": .string(reply), "source": .string(text == nil ? "hook" : "transcript")]
  }

  /// Runs on the state queue. It returns a function that finds the session's
  /// transcript, so that the file checks and the folder search run off the queue.
  func transcriptFinder(_ id: String) -> () -> String? {
    let e = entries[id]!
    let account = paneEnv(id)["CLAUDE_CONFIG_DIR"] ?? ClaudeAccount.defaultFolder
    let session = e.session
    let known = e.facts.transcriptPath
    let machine = self.machine(for: session)
    return {
      if let known, machine.exists(known) { return known }
      return session.started
        ? Transcript.find(session.claudeSessionId, account: account, cwd: session.cwd, on: machine) : nil
    }
  }

  // MARK: Summaries

  /// Starts each model call that `verdict` asks for: the turn's summary and the PR's merge brief.
  func startSummaries(_ id: String, _ verdict: Verdict) {
    summarizeTurn(id, verdict)
    summarizeMerge(id, verdict)
  }

  /// Starts the summary of the turn that just ended, when `verdict`, the
  /// session's current verdict, comes from the last reply and no card or
  /// rule decides it. The result is a `triage` event keyed by the Stop event.
  /// sbd calls it after each event and tick, and once at startup. A turn gets
  /// one attempt per run of sbd.
  func summarizeTurn(_ id: String, _ verdict: Verdict) {
    guard config.triage.enabled, let e = entries[id], Triage.needsSummary(e.facts, verdict) else { return }
    let stop = e.facts.lastStop
    guard e.summaryAttempt != stop else { return }
    // A skip records an event, which calls this again. Setting `summaryAttempt` first makes that call return at the
    // guard above.
    entries[id]?.summaryAttempt = stop
    let account = config.triage.account.map(ClaudeAccount.normalize) ?? claudeAccount(of: id)
    if let skip = summarySkip(e.facts, account: account) {
      record(id, "triage", ["stop": .number(Double(stop)), "skipped": .string(skip)])
      return
    }
    let session = summary(id)
    guard Triage.summarizes(session.kind) else { return }
    let reply = e.facts.lastReply ?? ""
    let input = TriageSummarizer.input(session: session, reply: reply)
    let env = headlessEnv(session: id, account: config.triage.account)
    triageJobs.addOperation { [self] in
      let result = Result {
        try TriageSummarizer.parse(
          triageCall(TriageSummarizer.arguments(model: config.triage.model), input, env), reply: reply)
      }
      queue.async { self.finishSummary(id, stop: stop, result) }
    }
  }

  /// Starts the model's brief of the session's PR when `verdict` asks the
  /// user to merge or enqueue it, the poller read the PR's details at its
  /// head, and no brief exists for that head. The result is a `mergeBrief`
  /// event. A head gets one call per run of sbd. A head whose call the budget
  /// skipped gets its call on the first tick after the budget returns. A
  /// session that wrote its own card gets none, because its card shows no
  /// rule's summary.
  func summarizeMerge(_ id: String, _ verdict: Verdict) {
    guard config.triage.enabled, verdict.summarizesPR, let e = entries[id], e.facts.sessionSummary == nil,
      let pr = e.facts.pr, let details = pr.mergeDetails, e.facts.currentMergeBrief == nil
    else { return }
    let attempt = "#\(pr.number)@\(pr.headSha)"
    guard e.mergeBriefAttempt != attempt || e.mergeBriefSkipped else { return }
    let account = config.triage.account.map(ClaudeAccount.normalize) ?? claudeAccount(of: id)
    let skip = budgetSkip(e.facts, account: account)
    // A head records one skip, and then waits for the budget.
    if e.mergeBriefAttempt == attempt, skip != nil { return }
    // A skip records an event, which calls this again.
    entries[id]?.mergeBriefAttempt = attempt
    entries[id]?.mergeBriefSkipped = skip != nil
    let key: [String: JSON] = ["pr": .number(Double(pr.number)), "head": .string(pr.headSha)]
    if let skip {
      record(id, MergeBrief.event, .object(key.merging(["skipped": .string(skip)]) { $1 }))
      return
    }
    let input = MergeBrief.input(pr, description: details.description)
    let env = headlessEnv(session: id, account: config.triage.account)
    let (number, title) = (pr.number, pr.title)
    triageJobs.addOperation { [self] in
      let result = Result {
        try MergeBrief.parse(triageCall(MergeBrief.arguments(model: config.triage.model), input, env), title: title)
      }
      queue.async {
        guard self.entries[id] != nil else { return }
        var data = key
        switch result {
        case .success(let text): data["text"] = .string(text)
        case .failure(let error):
          logLine("can't summarize #\(number) of \(id): \(error)")
          data["error"] = .string("\(error)")
        }
        self.record(id, MergeBrief.event, .object(data))
      }
    }
  }

  /// Runs one `claude -p` call under the triage settings, off the state queue.
  private func triageCall(_ arguments: [String], _ input: String, _ env: [String: String]) throws -> String {
    try runHeadless(arguments, input: input, env: env, folder: home.path, timeout: config.triage.timeoutSeconds)
  }

  /// Why the turn summary does not run: the session wrote its card, or the budget is spent.
  private func summarySkip(_ facts: SessionFacts, account: String) -> String? {
    if facts.sessionSummary != nil { return "the session wrote its card" }
    return budgetSkip(facts, account: account)
  }

  /// Why a model call does not run: the account has no quota left, or the
  /// session had its calls for the hour.
  private func budgetSkip(_ facts: SessionFacts, account: String) -> String? {
    if !quota.hasBudget(account: account) { return "no quota left for \(account)" }
    let now = nowMs()
    let calls = facts.summaryCalls.filter { now - $0 < AutoContinue.hourMs }.count
    if calls >= config.triage.perHour { return "\(calls) summaries in the last hour" }
    return nil
  }

  private func finishSummary(_ id: String, stop: Int64, _ result: Result<TriageSummary, Error>) {
    // A call for a turn the user moved on from still counts toward
    // `triage.perHour`. applyTriage ignores its summary because its stop no
    // longer matches.
    guard entries[id] != nil else { return }
    var data: [String: JSON]
    switch result {
    case .success(let summary):
      data = (try? JSON(encoding: summary).object) ?? [:]
    case .failure(let error):
      logLine("can't summarize the reply of \(id): \(error)")
      data = ["error": .string("\(error)")]
    }
    data["stop"] = .number(Double(stop))
    record(id, "triage", .object(data))
  }
}
