import Foundation
import SwitchboardCore

/// `sb operator [<text>] [--log]`. It opens the operator, and creates it when none exists. `report`,
/// `reports`, `approve`, `model`, and `judge` are reserved first words.
func operatorCommand(_ a: Args) {
  switch a.positional.first {
  case "report": return operatorReport(a)
  case "reports": return operatorReports(a)
  case "approve": return operatorApprove(a)
  case "model": return operatorModel(a)
  case "judge": return operatorJudge(a)
  default: break
  }
  if a.switches.contains("--log") { return printChatLog(a, ["operator": true]) }
  var args = fromArg
  let text = a.positional.joined(separator: " ")
  if !text.isEmpty { args["text"] = .string(text) }
  printOpenOrSend(a, call("operator", args, timeout: 300))
}

/// `sb operator report [--needs-you] [--session S] <text>`, which only the operator runs.
private func operatorReport(_ a: Args) {
  let text = a.positional.dropFirst().joined(separator: " ")
  if text.isEmpty { die("operator report needs text") }
  var args = callerArg
  args["text"] = .string(text)
  args["needsYou"] = .bool(a.switches.contains("--needs-you"))
  if let about = a.values["--session"] { args["session"] = .string(about) }
  let result = call("operator-report", args)
  if a.json { return printJSON(result) }
  print(reportLine(result))
}

/// `sb operator approve <wait>`, which only the operator runs: it approves the merge that a `judgment needed`
/// message asks about.
private func operatorApprove(_ a: Args) {
  guard a.positional.count == 2 else { die("operator approve needs one wait id") }
  var args = callerArg
  args["wait"] = .string(a.positional[1])
  let result = call("wait-approve", args)
  if a.json { return printJSON(result) }
  print("approved wait \(a.positional[1]). sbd checks it again before it merges.")
}

/// `sb operator reports [--all]`: the operator's reports, oldest first.
private func operatorReports(_ a: Args) {
  let result = call("operator-reports", a.switches.contains("--all") ? ["all": true] : [:])
  if a.json { return printJSON(result) }
  for row in result.array ?? [] { print(reportLine(row)) }
}

/// A report on one line: its time, whether it is open, the session that it is about, and its text.
private func reportLine(_ row: JSON) -> String {
  let time = Wait.formatTime(Int64(row["t"]?.int ?? 0))
  let status = row["open"]?.bool == true ? "open" : row["needsYou"]?.bool == true ? "closed" : "info"
  let about = row["aboutName"]?.string.map { "\($0): " } ?? ""
  return "\(time)  \(status)  \(about)\(row["text"]?.string ?? "")".printable
}

/// `sb operator model [<name>]`.
private func operatorModel(_ a: Args) {
  var args: [String: JSON] = [:]
  let words = a.positional.dropFirst()
  if let model = words.first {
    guard words.count == 1 else { die("operator model takes one model name") }
    // A conversation that read injected instructions could otherwise move the operator to a pricier model.
    refuseInsideClaudeCode("operator model <name> needs the user, so it doesn't run inside Claude Code")
    args["model"] = .string(model)
  }
  let result = call("operator-model", args)
  if a.json { return printJSON(result) }
  print("The operator and its judges run \(result["model"]?.string ?? "")".printable)
  if !args.isEmpty { print("The operator switches when its claude next starts.") }
}

/// `sb operator judge --kind K --input FILE [--model M]`.
private func operatorJudge(_ a: Args) {
  guard let kind = a.values["--kind"], let path = a.values["--input"] else {
    die("usage: sb operator judge --kind reply-gate|ci-failure|pick-issues --input <file> [--model M]")
  }
  guard let text = try? String(contentsOfFile: path, encoding: .utf8), let input = JSON.parse(text), input.object != nil
  else { die("\(path) isn't a JSON object") }
  var args: [String: JSON] = ["kind": .string(kind), "input": input]
  if let model = a.values["--model"] { args["model"] = .string(model) }
  let result = call("operator-judge", args, timeout: 300)
  if a.json { return printJSON(result) }
  print("\(result["answer"]?.string ?? "")  \(result["detail"]?.string ?? "")".printable)
}
