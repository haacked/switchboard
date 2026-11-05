import Foundation
import SwitchboardCore

extension Service {
  func triageRequest(_ op: String, _ args: JSON) throws -> Response {
    switch op {
    case "triage":
      return .success(try queue.sync { try JSON(encoding: Triage.order(summaries())) })
    case "choose":
      return handle(try queue.sync { try chooseRequest(args) })
    default:
      return .success(try reply(args))
    }
  }

  /// The request that does what a click on the option does: answer the
  /// session's card, or send the option's message.
  private func chooseRequest(_ args: JSON) throws -> Request {
    let id = try lookup(args)
    let name = entries[id]!.session.name
    guard let item = summary(id).triage else { throw APIError("\(name) needs nothing from you") }
    guard !item.options.isEmpty else { throw APIError("\(name) offers no options. Send it a message instead") }
    // The caller's `ref` names the item that the user saw. `refuseCards` is set
    // inside Claude Code, which may not approve a prompt.
    if let ref = args["ref"]?.string, ref != item.ref {
      throw APIError("\(name) has a new item since you looked. Look again")
    }
    if args["refuseCards"]?.bool == true, item.source == .card {
      throw APIError("choose answers a permission prompt or question for you, so it doesn't run inside Claude Code")
    }
    guard let key = args["option"]?.string else { throw APIError("name an option, by number or label") }
    let option = try item.option(key)
    guard item.source == .card, let card = entries[id]!.facts.cards.first else {
      return Request(op: "send", args: ["session": .string(id), "text": .string(option.message)])
    }
    var answer: [String: JSON] = ["session": .string(id), "card": .number(Double(card.id))]
    if card.kind != .question {
      answer["behavior"] = .string(option.message)
    } else {
      answer["answers"] = [.string(option.message)]
    }
    return Request(op: "answer", args: .object(answer))
  }

  /// The session's last assistant reply from its transcript, which is read
  /// off the state queue, else the one its Stop hook reported.
  private func reply(_ args: JSON) throws -> JSON {
    let (id, findTranscript, hooked) = try queue.sync { () -> (String, () -> String?, String?) in
      let id = try lookup(args)
      return (id, transcriptFinder(id), entries[id]!.facts.lastReply)
    }
    let text = findTranscript().flatMap { Transcript.tail($0).lastReply }
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
    return {
      if let known, FileManager.default.fileExists(atPath: known) { return known }
      return session.started ? Transcript.find(session.claudeSessionId, account: account, cwd: session.cwd) : nil
    }
  }

  // MARK: Summaries

  /// Starts the summary of the turn that just ended, when its last reply
  /// decides the session's state and no card or rule does. The result is a
  /// `triage` event keyed by the Stop event.
  func summarizeTurn(_ id: String) {
    guard config.triage.enabled, let e = entries[id] else { return }
    guard Triage.needsSummary(e.facts, Attention.evaluate(e.session, e.facts, now: nowMs(), stateOf: lastState)) else {
      return
    }
    let session = summary(id)
    guard Triage.mayHaveItem(session) else { return }
    let stop = e.facts.lastStop
    let input = TriageSummarizer.input(session: session, reply: e.facts.lastReply ?? "")
    let env = headlessEnv(session: id, account: config.triage.account)
    triageJobs.addOperation { [self] in
      let result = Result {
        try TriageSummarizer.parse(
          runHeadless(
            TriageSummarizer.arguments(model: config.triage.model), input: input, env: env, folder: home.path,
            timeout: config.triage.timeoutSeconds))
      }
      queue.async { self.finishSummary(id, stop: stop, result) }
    }
  }

  private func finishSummary(_ id: String, stop: Int64, _ result: Result<TriageSummary, Error>) {
    // The user moved on while the call ran.
    guard entries[id]?.facts.lastStop == stop else { return }
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
