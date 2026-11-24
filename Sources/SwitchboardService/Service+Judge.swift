import Foundation
import SwitchboardCore

/// The Operator's judges: one-shot `claude -p` calls that answer a bounded question before the Operator wakes.
extension Service {
  /// Runs one call of the judge `spec` about the session `session`, the wait `wait`, and the PR head `head`, and
  /// records a `judge` event on the Operator with the word that `spec` gives for a parsed answer.
  ///
  /// The call runs `operator.model` under `triage.account`, or under the Operator's pane environment when that
  /// is unset, and ends after `triage.timeoutSeconds`. It returns nil and runs nothing when the account has no quota
  /// left or sbd can't create the Operator. It runs off the state queue.
  func judge<J: OperatorJudge.Spec>(
    _ spec: J.Type, session: String, wait: String, head: String, input: String
  ) -> Result<J.Answer, Error>? {
    let kind = J.kind
    let model = operatorSettings.model
    let setup: (op: String, env: [String: String])? = queue.sync {
      let op: String
      do { op = try ensureOperator() } catch {
        logLine("can't run the \(kind.rawValue) judge for wait \(wait): \(error)")
        return nil
      }
      let triage = triageAccount(for: op)
      guard quota.hasBudget(account: triage.key) else {
        logLine("skipping the \(kind.rawValue) judge for wait \(wait): no quota left for \(triage.key)")
        return nil
      }
      return (op, headlessEnv(session: op, account: triage.account))
    }
    guard let setup else { return nil }
    let call = headlessCall(
      kind.headless, session: session, arguments: J.arguments(model: model), input: input, env: setup.env,
      folder: home.path, timeout: config.triage.timeoutSeconds, parse: J.parse)
    var data: [String: JSON] = [
      "kind": .string(kind.rawValue), "session": .string(session), "wait": .string(wait), "head": .string(head),
      "model": .string(model),
    ]
    // `model` names the configured judge model on every event, so a call that printed no envelope groups with one
    // that did. The model that claude reported goes in `resolvedModel`.
    var reported = call.reply?.eventFields ?? [:]
    reported["resolvedModel"] = reported.removeValue(forKey: "model")
    data.merge(reported) { $1 }
    if let usage = call.reply?.usage {
      data["inputTokens"] = .number(Double(usage.input))
      data["outputTokens"] = .number(Double(usage.output))
    }
    switch call.result {
    case .success(let value):
      data["answer"] = .string(J.word(value))
    case .failure(let error):
      logLine("the \(kind.rawValue) judge for wait \(wait) failed: \(error)")
      data["error"] = .string("\(error)")
    }
    queue.sync { _ = record(setup.op, OperatorJudge.event, .object(data)) }
    return call.result
  }
}
