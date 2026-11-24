import Foundation
import SwitchboardCore

/// `sb operator judge`: one judgment through the same prompt builders, schema, account, and timeout that sbd uses
/// for the operator's judges, for the model eval.
extension Service {
  /// The `operator-judge` request. `kind` is `reply-gate`, `ci-failure`, or `pick-issues`, `input` holds the
  /// arguments of that kind's prompt builder, and `model` overrides `operator.model` for this call. The answer is
  /// `kind`, `model`, `answer` (the answer word, or the picked refs), `detail` (the question, the message, or the
  /// reasons), and the tokens that claude reported. The call records a `headless_calls` row and nothing else, and it
  /// acts on nothing. It runs off the state queue.
  func operatorJudge(_ args: JSON, clientGone: @escaping @Sendable () -> Bool) throws -> JSON {
    guard let kind = args["kind"]?.string, let input = args["input"]?.object else {
      throw APIError("operator-judge needs a kind and an input object")
    }
    let model = args["model"]?.string ?? operatorSettings.model
    if let problem = Manager.modelProblem(model) { throw APIError(problem) }
    // An existing operator gives the live judges' account. Without one, the call takes `triage.account` or the active
    // account, so an eval never creates or launches an operator.
    let (account, env): (String, [String: String]) = queue.sync {
      if let op = operatorID(quiet: true) {
        let triage = triageAccount(for: op)
        return (triage.key, headlessEnv(session: op, account: triage.account))
      }
      let account = triageClaudeAccount ?? activeAccount
      return (account.folder, headlessEnv(session: nil, account: account))
    }
    guard quota.hasBudget(account: account) else { throw APIError("no quota is left for \(account)") }
    func text(_ key: String) throws -> String {
      guard let value = input[key]?.string else { throw APIError("the \(kind) input needs \"\(key)\" as text") }
      return value
    }
    func number(_ key: String) throws -> Int {
      guard let value = input[key]?.int else { throw APIError("the \(kind) input needs \"\(key)\" as a number") }
      return value
    }
    let triageTimeout = config.triage.timeoutSeconds
    func run<T>(
      _ headless: HeadlessKind, _ arguments: [String], _ prompt: String,
      timeout: Double, parse: (String) throws -> T
    ) throws -> (T, HeadlessReply?) {
      let call = headlessCall(
        headless, session: nil, arguments: arguments, input: prompt, env: env, folder: home.path, timeout: timeout,
        cancelled: clientGone, parse: parse)
      return (try call.result.get(), call.reply)
    }
    let (answer, detail, reply): (String, String, HeadlessReply?)
    switch kind {
    case OperatorJudge.Kind.replyGate.rawValue:
      let (parsed, reply0) = try run(
        .replyGate, OperatorJudge.ReplyGate.arguments(model: model),
        OperatorJudge.ReplyGate.input(
          repo: try text("repo"), number: try number("number"), title: try text("title"), session: try text("session"),
          reply: try text("reply")),
        timeout: triageTimeout, parse: OperatorJudge.ReplyGate.parse)
      (answer, detail, reply) = (
        parsed.word.rawValue, parsed.question.isEmpty ? parsed.reason : parsed.question, reply0
      )
    case OperatorJudge.Kind.ciFailure.rawValue:
      let jobs = Array(
        (input["jobs"]?.array ?? []).flatMap { job in
          OperatorJudge.CIFailure.jobs(workflow: job["workflow"]?.string ?? "", log: job["log"]?.string ?? "")
        }.prefix(OperatorJudge.CIFailure.maxJobs))
      guard !jobs.isEmpty else { throw APIError("the ci-failure input needs jobs, each with a workflow and a log") }
      let (parsed, reply0) = try run(
        .ciFailure, OperatorJudge.CIFailure.arguments(model: model),
        OperatorJudge.CIFailure.input(
          repo: try text("repo"), number: try number("number"), title: try text("title"), head: try text("head"),
          jobs: jobs),
        timeout: triageTimeout, parse: OperatorJudge.CIFailure.parse)
      (answer, detail, reply) = (parsed.cause.rawValue, parsed.message, reply0)
    case "pick-issues":
      let repo = try text("repo")
      let candidates: [TopupCandidates.Candidate] = (input["candidates"]?.array ?? []).compactMap { item in
        if let prompt = item["followup"]?.string, let id = item["id"]?.string {
          return .followup(id: id, prompt: prompt)
        }
        guard let number = item["number"]?.int, let title = item["title"]?.string else { return nil }
        return .issue(
          InboxIssue(
            repo: repo, number: number, title: title, url: "https://github.com/\(repo)/issues/\(number)",
            body: item["body"]?.string ?? "", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"))
      }
      guard !candidates.isEmpty else { throw APIError("the pick-issues input needs candidates") }
      let sessions = (input["sessions"]?.array ?? []).compactMap(\.string).enumerated().map { index, name in
        QueueStatus.Row(
          id: "eval\(index)", name: name, kind: .work, group: nil, repository: repo, repositoryRead: true,
          markedDone: false, paused: false, removing: false, state: .working, unreadHost: false, prMerged: false,
          hasMergeAction: false, hasRemovalAction: false, started: true, startWaitingForSlot: false)
      }
      let k = input["k"]?.int ?? 1
      let (parsed, reply0) = try run(
        .topupPick, TopupPick.arguments(model: model),
        TopupPick.input(rubric: try text("rubric"), k: k, candidates: candidates, sessions: sessions),
        timeout: Double(operatorSettings.topupTimeoutSeconds),
        parse: { try TopupPick.parse($0, candidates: candidates, k: k) })
      answer = parsed.picks.map(\.ref).joined(separator: ",")
      detail = parsed.picks.map { "\($0.ref): \($0.reason)" }.joined(separator: " ")
      reply = reply0
    default:
      throw APIError("the kind is reply-gate, ci-failure, or pick-issues")
    }
    var result: [String: JSON] = [
      "kind": .string(kind), "model": .string(model), "answer": .string(answer), "detail": .string(detail),
    ]
    if let usage = reply?.usage {
      result["inputTokens"] = .number(Double(usage.input))
      result["outputTokens"] = .number(Double(usage.output))
    }
    return .object(result)
  }
}
