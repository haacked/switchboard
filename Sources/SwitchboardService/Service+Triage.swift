import Foundation
import SwitchboardCore

extension Service {
  /// `caller` sent the request. A `choose` that allows a `script` card passes it on, so the answer checks the
  /// sender of the click as `sb allow` does.
  func triageRequest(_ request: Request, origin: RequestOrigin, caller: Caller) throws -> Response {
    let args = request.args
    switch request.op {
    case "triage":
      return .success(try queue.sync { try JSON(encoding: Triage.order(summaries())) })
    case "choose":
      let (chosen, answersScript) = try queue.sync {
        let chosen = try chooseRequest(args)
        return (chosen, chosen.op == "answer" && (try? chosenCard(chosen.args))?.kind == .script)
      }
      return handle(chosen, caller: answersScript ? caller : .inProcess)
    case "summary-set":
      return .success(
        try queue.sync {
          try requireOnHost(request, origin: origin)
          return try setSummary(args, origin: origin)
        })
    case "item-context":
      return .success(try itemContext(args))
    default:
      return .success(try reply(request, origin: origin))
    }
  }

  /// Records the card that the session wrote for its current turn. A new
  /// prompt drops it. When the card asks the user something, `childItems`
  /// lists the session's children that ask the user in their own Inbox item,
  /// so the CLI can say not to ask their questions again. A clarifying turn's card would replace the item that
  /// the user asked from, so sbd refuses it.
  private func setSummary(_ args: JSON, origin: RequestOrigin) throws -> JSON {
    let id = try lookup(args)
    if let ask = entries[id]!.facts.clarifying, ask.started {
      throw APIError(
        "This turn answers a question about decision \(ask.number). Switchboard did not save a summary card. Reply in text, and Switchboard shows your reply under that decision."
      )
    }
    guard let raw = args["card"] else { throw APIError("summary set needs the card as JSON") }
    let cleaned = try TriageCard.clean(raw, now: nowMs())
    let event = record(id, Triage.sessionEvent, try JSON(encoding: cleaned.card))
    let asks = !cleaned.card.options.isEmpty || !cleaned.card.decisions.isEmpty
    return [
      "session": .string(id), "event": .number(Double(event.id)),
      "options": .number(Double(cleaned.card.options.count)),
      "callouts": .number(Double(cleaned.card.callouts.count)),
      "decisions": .number(Double(cleaned.card.decisions.count)),
      "drafts": .number(Double(cleaned.card.drafts.count)),
      "dropped": .array(cleaned.dropped.map(JSON.string)),
      "childItems": .array(asks ? childItems(of: id, for: origin) : []),
    ]
  }

  /// The children of `id` that ask the user in their Inbox item, sorted by name. A child asks when it is in Needs
  /// you, or when its item is the card that it wrote. The list leaves out a Ready to merge child that shows only
  /// sbd's merge item, because whether to merge is the parent's own decision.
  private func childItems(of id: String, for origin: RequestOrigin) -> [JSON] {
    let watched = watchedSlackKeys(now: nowMs())
    let children: [SessionSummary] = entries.values.filter { parentOf($0.session) == id }
      .map { summary($0.session.id, watchedSlack: watched, for: origin) }
    var items: [JSON] = []
    for child in children.sorted(by: { $0.name < $1.name }) {
      guard let item = child.triage, child.state == .needsYou || item.source == .session else { continue }
      let url = SessionLink.url(for: child.id).absoluteString
      items.append(
        ["session": .string(child.id), "name": .string(child.name), "url": .string(url), "title": .string(item.title)])
    }
    return items
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
    // Claude Code may not approve its own prompt, act on its own PR, or answer the operator's report for the user.
    if item.source == .card || item.source == .report || option.action.needsClick {
      try Service.refuseClaude(args, "choose answers a prompt, answers a report, or acts on a PR")
    }
    let session = JSON.string(id)
    // The ref lets `send` record that the user's message answered a rule's item. `send` drops it for a choice
    // made inside Claude Code, as by the Manager.
    let insideClaude = args["insideClaude"] ?? false
    func send(_ text: String) -> Request {
      Request(
        op: "send",
        args: ["session": session, "text": .string(text), "ref": .string(item.ref), "insideClaude": insideClaude])
    }
    switch option.action {
    case .send:
      return send(option.message ?? option.label)
    case .reply:
      let text = args["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !text.isEmpty else { throw APIError("\(option.label) needs the text to send") }
      if item.source == .report { return try operatorReply(id, item, text, insideClaude: insideClaude) }
      return send(text)
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
      // A card stored before `TriageCard.clean` refused actions may still hold one.
      if let action = option.wait?.actionKind { throw TriageCard.armsAction(action) }
      var wait = try option.wait.map { try JSON(encoding: $0).object ?? [:] } ?? [:]
      wait["session"] = session
      return Request(op: "wait", args: .object(wait))
    case .done:
      return Request(op: "done", args: ["session": session])
    case .allow, .deny, .allowAutoMode, .answer:
      // A conversation's item can name a card behind a send card.
      guard item.source == .card, let card = entries[id]!.facts.cards.first(where: { $0.ref == item.ref }) else {
        throw APIError("\(name) has no prompt to answer")
      }
      var answer: [String: JSON] = ["session": session, "card": .number(Double(card.id))]
      switch option.action {
      case .answer: answer["answers"] = [.string(option.message ?? option.label)]
      case .allowAutoMode:
        answer["behavior"] = "allow"
        answer[AllowExtra.autoMode.argument] = true
      default: answer["behavior"] = .string(option.action.rawValue)
      }
      return Request(op: "answer", args: .object(answer))
    }
  }

  /// The request that sends the reply on `id`'s ask item to the operator. It names the session, unless `id` is the
  /// operator, and carries the ids of the asks on `id` up to the one that the item's ref names. The `sent` event
  /// closes exactly those reports.
  private func operatorReply(_ id: String, _ item: TriageItem, _ text: String, insideClaude: JSON) throws -> Request {
    guard let op = operatorID() else { throw APIError("there is no operator to answer") }
    guard let latest = Triage.reportID(ref: item.ref) else {
      throw APIError("\(entries[id]!.session.name) has no question from the operator to answer")
    }
    let ids = entries[id]!.facts.operatorItems.asks.map(\.id).filter { $0 <= latest }
    return Request(
      op: "send",
      args: [
        "session": .string(op), "text": .string(id == op ? text : "About \(entries[id]!.session.name): \(text)"),
        "reports": .array(ids.map { .number(Double($0)) }), "ref": .string(item.ref), "insideClaude": insideClaude,
      ])
  }

  /// The session's last assistant reply from its transcript, which is read
  /// off the state queue, else the one its Stop hook reported.
  private func reply(_ request: Request, origin: RequestOrigin) throws -> JSON {
    let (id, findTranscript, machine, hooked) = try queue.sync {
      () -> (String, () -> String?, any Machine, String?) in
      try requireOnHost(request, origin: origin)
      let id = try lookup(request.args)
      return (id, transcriptFinder(id), try site(of: id).machine, entries[id]!.facts.lastReply)
    }
    let text = findTranscript().flatMap { Transcript.tail($0, on: machine).lastReply }
    guard let reply = text ?? hooked else { throw APIError("\(id) has no reply yet") }
    return ["session": .string(id), "reply": .string(reply), "source": .string(text == nil ? "hook" : "transcript")]
  }

  /// The `item-context` request: the transcript steps that lead up to the
  /// session's current item, as `ItemContext`. `steps` counts the steps
  /// before the anchor, from 1 to `ItemContext.maxSteps`. Like `chatLog`'s
  /// assistant-only read, it returns only Claude's steps, so it serves any
  /// session. It reads the transcript off the state queue.
  private func itemContext(_ args: JSON) throws -> JSON {
    let (id, ref, anchor, findTranscript, machine) = try queue.sync {
      () -> (String, String?, TranscriptAnchor, () -> String?, any Machine) in
      let id = try lookup(args)
      let item = summary(id).triage
      let facts = entries[id]!.facts
      let anchor = TranscriptAnchor.of(item: item, facts: facts)
      return (id, item?.ref, anchor, transcriptFinder(id), try site(of: id).machine)
    }
    let steps = min(max(args["steps"]?.int ?? ItemContext.defaultSteps, 1), ItemContext.maxSteps)
    let read = findTranscript().map { Transcript.context($0, anchor: anchor, steps: steps, on: machine) }
    return try JSON(
      encoding: ItemContext(
        session: id, ref: ref, anchor: anchor.kind, anchored: read?.anchored ?? false, more: read?.more ?? false,
        steps: read?.steps ?? []))
  }

  /// Runs on the state queue. It returns a function that finds the session's
  /// transcript, so that the file checks and the folder search run off the queue.
  func transcriptFinder(_ id: String) -> () -> String? {
    let e = entries[id]!
    let session = e.session
    let account = session.host == nil ? paneAccountFolder(id) : transcriptAccount(session)
    let known = e.facts.transcriptPath
    let machine = site(for: session).machine
    return {
      if let known, machine.exists(known) { return known }
      return session.started
        ? Transcript.find(session.claudeSessionId, account: account, cwd: session.cwd, on: machine) : nil
    }
  }

  // MARK: Summaries

  /// The account of a one-shot call that sbd makes for the session `id`: `triage.account` when it is set, or else
  /// `headlessAccount(of:)`.
  func triageAccount(for id: String) -> (key: String, account: ClaudeAccount?) {
    if let account = triageClaudeAccount { return (account.folder, account) }
    return headlessAccount(of: id)
  }

  /// The account of a one-shot call that runs as the session `id`. `key` is the account that the call's quota
  /// counts against. `account` is the override that `headlessEnv` applies. It is nil when the call takes the
  /// session's pane environment. A session whose account is a Codex folder takes `headlessStandIn`, because
  /// claude can't run under a Codex folder.
  func headlessAccount(of id: String) -> (key: String, account: ClaudeAccount?) {
    let own = claudeAccount(of: id)
    switch own {
    case .local, .host: return (own.key, nil)
    case .codex: return (headlessStandIn.folder, headlessStandIn)
    }
  }

  /// The Claude account that a one-shot turn runs under in place of a Codex folder: `triage.account`, else the
  /// active account.
  var headlessStandIn: ClaudeAccount { triageClaudeAccount ?? activeAccount }

  /// `triage.account`, or nil when it is unset or names a Codex folder.
  var triageClaudeAccount: ClaudeAccount? {
    config.triage.account.flatMap { claudeAccount(folder: $0) }
  }

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
    let triage = triageAccount(for: id)
    if let skip = summarySkip(e.facts, account: triage.key) {
      record(id, "triage", ["stop": .number(Double(stop)), "skipped": .string(skip)])
      return
    }
    var session = summary(id)
    // The summary describes the turn for when the item shows, so the model reads sbd's state, not a snooze's Waiting.
    session.state = verdict.state
    guard Triage.summarizes(session.kind) else { return }
    let reply = e.facts.lastReply ?? ""
    let input = TriageSummarizer.input(session: session, reply: reply)
    let env = headlessEnv(session: id, account: triage.account)
    triageJobs.addOperation { [self] in
      let call = headlessCall(
        .triage, session: id, arguments: TriageSummarizer.arguments(model: config.triage.model), input: input, env: env,
        folder: home.path, timeout: config.triage.timeoutSeconds
      ) { try TriageSummarizer.parse($0, reply: reply) }
      queue.async { self.finishSummary(id, stop: stop, call) }
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
    let triage = triageAccount(for: id)
    let skip = budgetSkip(e.facts, account: triage.key)
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
    let env = headlessEnv(session: id, account: triage.account)
    let (number, title) = (pr.number, pr.title)
    triageJobs.addOperation { [self] in
      let call = headlessCall(
        .mergeBrief, session: id, arguments: MergeBrief.arguments(model: config.triage.model), input: input, env: env,
        folder: home.path, timeout: config.triage.timeoutSeconds
      ) { try MergeBrief.parse($0, title: title) }
      queue.async {
        guard self.entries[id] != nil else { return }
        var data = key.merging(call.reply?.eventFields ?? [:]) { $1 }
        switch call.result {
        case .success(let text): data["text"] = .string(text)
        case .failure(let error):
          logLine("can't summarize #\(number) of \(id): \(error)")
          data["error"] = .string("\(error)")
        }
        self.record(id, MergeBrief.event, .object(data))
      }
    }
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

  private func finishSummary(_ id: String, stop: Int64, _ call: HeadlessOutcome<TriageSummary>) {
    // A call for a turn the user moved on from still counts toward
    // `triage.perHour`. applyTriage ignores its summary because its stop no
    // longer matches.
    guard entries[id] != nil else { return }
    var data: [String: JSON]
    switch call.result {
    case .success(let summary):
      data = (try? JSON(encoding: summary).object) ?? [:]
    case .failure(let error):
      logLine("can't summarize the reply of \(id): \(error)")
      data = ["error": .string("\(error)")]
    }
    data["stop"] = .number(Double(stop))
    data.merge(call.reply?.eventFields ?? [:]) { $1 }
    record(id, "triage", .object(data))
  }
}
