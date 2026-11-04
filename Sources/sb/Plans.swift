import Foundation
import SwitchboardCore

func plan(_ a: Args) {
  let words = Array(a.positional.dropFirst())
  func owner(_ args: inout [String: JSON]) {
    if let group = a.values["--group"] { args["group"] = .string(group) }
    if let session = a.values["--session"] { args["session"] = .string(session) }
  }
  func named(_ command: String) -> [String: JSON] {
    guard let ref = words.first else { die("plan \(command) needs a plan") }
    return ["plan": .string(ref)]
  }
  switch a.positional.first {
  case "ls", "list", nil:
    var args: [String: JSON] = [:]
    owner(&args)
    let result = call("plan-ls", args)
    if a.json { return printJSON(result) }
    let list = decode(result, as: [PlanSummary].self)
    if list.isEmpty { print("No plans. Attach one with: sb plan attach <doc> --group <group>") }
    for p in list { printPlan(p, indent: "") }
  case "attach", "add":
    guard let doc = words.first else { die("plan attach needs a document") }
    var args: [String: JSON] = ["doc": .string(doc), "cwd": .string(FileManager.default.currentDirectoryPath)]
    if let path = a.values["--path"] { args["path"] = .string(path) }
    owner(&args)
    printPlanDocument(call("plan-attach", args, timeout: 120), json: a.json)
  case "detach", "rm":
    let result = call("plan-detach", named("detach"))
    if a.json { return printJSON(result) }
    print("detached \(result["detached"]?.string ?? "")")
  case "get", "show":
    printPlanDocument(call("plan-get", named("get")), json: a.json)
  case "update", "write":
    let result = call("plan-update", named("update"), timeout: 120)
    if a.json { return printJSON(result) }
    let p = decode(result, as: PlanDocument.self)
    print(
      result["wrote"]?.bool == true ? "wrote the table to \(p.source.text)" : "\(p.source.text) already holds the table"
    )
  case "auto":
    guard words.count == 2, ["on", "off"].contains(words[1]) else { die("usage: sb plan auto <plan> on|off") }
    printPlanDocument(call("plan-auto", ["plan": .string(words[0]), "on": .bool(words[1] == "on")]), json: a.json)
  default:
    die("usage: sb plan ls|attach|detach|get|update|auto")
  }
}

private func printPlanDocument(_ result: JSON, json: Bool) {
  if json { return printJSON(result) }
  let p = decode(result, as: PlanDocument.self)
  print("\(p.id)  \(p.source.text)".printable)
  if let group = p.group { print("  group:   \(group)") }
  if let session = p.session { print("  session: \(session)") }
  print("  read:    \(p.read.map(ago) ?? "never")")
  if let error = p.error { print("  error:   \(oneLine(error, max: 200))".printable) }
  print("  links:   \(p.links.count) PRs, \(p.rows.count) rows")
  print(
    "  table:   \(p.statusBlock == nil ? "no \(Plans.startMarker) block" : "yes"), auto update \(p.autoUpdate ? "on" : "off")"
  )
  for row in PlanSummary(p).outOfDate { printRow(row, indent: "  ") }
}

/// One line for the plan, then a line for each out-of-date row.
func printPlan(_ p: PlanSummary, indent: String) {
  var line = "\(indent)plan: \(p.id) \(p.source.text) (\(p.rows) rows, \(p.outOfDate.count) out of date)"
  if let error = p.error { line += ", error: \(oneLine(error, max: 120))" }
  print(line.printable)
  for row in p.outOfDate { printRow(row, indent: indent + "  ") }
}

private func printRow(_ row: PlanRow, indent: String) {
  let changed = row.prs.filter(\.advanced).map { "\($0.link.text) \($0.now?.rawValue ?? "")" }
  print("\(indent)out of date: \(oneLine(row.text, max: 160)) (\(changed.joined(separator: ", ")))".printable)
}
