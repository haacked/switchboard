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
    let (id, known, find, hooked) = try queue.sync { () -> (String, String?, (() -> String?)?, String?) in
      let id = try lookup(args)
      let e = entries[id]!
      let account = paneEnv(id)["CLAUDE_CONFIG_DIR"] ?? ClaudeAccount.defaultFolder
      let session = e.session
      let find =
        session.started ? { Transcript.find(session.claudeSessionId, account: account, cwd: session.cwd) } : nil
      return (id, e.facts.transcriptPath, find, e.facts.lastReply)
    }
    // The file checks and the folder search run off the state queue.
    let path = known.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? find?()
    let text = path.flatMap { Transcript.tail($0).lastReply }
    guard let reply = text ?? hooked else { throw APIError("\(id) has no reply yet") }
    return ["session": .string(id), "reply": .string(reply), "source": .string(text == nil ? "hook" : "transcript")]
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
    var env = ProcessInfo.processInfo.environment.merging(paneEnv(id)) { $1 }
    // A summary call is not a session, so it gets no session id.
    env["SB_SESSION_ID"] = nil
    if let account = config.triage.account {
      ClaudeAccount.apply(account, to: &env)
    }
    triageJobs.addOperation { [self] in
      let result = Result { try runSummary(input, env: env) }
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

  /// Runs `claude -p` with the input on stdin, in the state folder, and ends
  /// it after the configured timeout.
  private func runSummary(_ input: String, env: [String: String]) throws -> TriageSummary {
    guard let claude = findExecutable(config.claude) else { throw APIError("can't find \(config.claude)") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: claude)
    p.arguments = TriageSummarizer.arguments(model: config.triage.model)
    p.environment = env
    p.currentDirectoryURL = URL(fileURLWithPath: home.path)
    let stdin = Pipe()
    let stdout = Pipe()
    p.standardInput = stdin
    p.standardOutput = stdout
    p.standardError = FileHandle.nullDevice
    try p.run()
    let timedOut = Flag()
    let limit = DispatchWorkItem {
      timedOut.set()
      p.terminate()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + config.triage.timeoutSeconds, execute: limit)
    stdin.fileHandleForWriting.write(Data(input.utf8))
    try? stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    limit.cancel()
    if timedOut.isSet { throw APIError("timed out after \(Int(config.triage.timeoutSeconds)) s") }
    guard p.terminationStatus == 0 else {
      throw APIError(
        "claude exited with status \(p.terminationStatus): \(oneLine(String(decoding: output, as: UTF8.self), max: 200))"
      )
    }
    return try TriageSummarizer.parse(String(decoding: output, as: UTF8.self))
  }
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool { lock.withLock { value } }
  func set() { lock.withLock { value = true } }
}
