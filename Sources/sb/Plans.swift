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
    // `sb plan attach <group> --artifact <url>` names the group first.
    guard let doc = a.values["--artifact"] ?? words.first else { die("plan attach needs a document") }
    var args: [String: JSON] = ["doc": .string(doc), "cwd": .string(FileManager.default.currentDirectoryPath)]
    if let path = a.values["--path"] { args["path"] = .string(path) }
    if a.values["--artifact"] != nil, let group = words.first { args["group"] = .string(group) }
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
    if p.source.kind == .artifact, result["wrote"]?.bool == true {
      print("proposed the table for \(p.source.text). Apply it with: sb plan artifact apply \(p.id)")
    } else {
      print(
        result["wrote"]?.bool == true
          ? "wrote the table to \(p.source.text)" : "\(p.source.text) already holds the table"
      )
    }
  case "followup":
    guard words.count == 2 else { die("usage: sb plan followup <plan> <row>") }
    let result = call("plan-followup", ["plan": .string(words[0]), "row": .string(words[1])])
    if a.json { printJSON(result) } else { printSession(summary(result)) }
  case "auto":
    guard words.count == 2, ["on", "off"].contains(words[1]) else { die("usage: sb plan auto <plan> on|off") }
    printPlanDocument(call("plan-auto", ["plan": .string(words[0]), "on": .bool(words[1] == "on")]), json: a.json)
  case "propose":
    let result = call("plan-propose", named("propose"), timeout: 300)
    if a.json { return printJSON(result) }
    let proposal = decode(result, as: PlanProposal.self)
    if result["applied"]?.bool == true { print("applied to \(proposal.source.text)".printable) }
    printProposal(proposal)
  case "proposals":
    var args: [String: JSON] = [:]
    if let group = a.values["--group"] { args["group"] = .string(group) }
    if let plan = a.values["--plan"] { args["plan"] = .string(plan) }
    let result = call("plan-proposals", args)
    if a.json { return printJSON(result) }
    let list = decode(result, as: [PlanProposal].self)
    if list.isEmpty { print("No proposals.") }
    list.forEach(printProposal)
  case "apply", "accept":
    guard let id = words.first else { die("plan apply needs a proposal") }
    printPlanDocument(call("plan-apply", ["proposal": .string(id)], timeout: 120), json: a.json)
  case "reject", "decline":
    guard let id = words.first else { die("plan reject needs a proposal") }
    let result = call("plan-reject", ["proposal": .string(id)])
    if a.json { return printJSON(result) }
    print("rejected \(result["rejected"]?.string ?? id)")
  case "artifact":
    artifact(a, words)
  default:
    die("usage: sb plan ls|attach|detach|get|update|followup|auto|artifact|propose|proposals|apply|reject")
  }
}

/// The proposal's id, kind, and plan, then its lines: `-` for a line it
/// replaces and `+` for the line it writes.
private func printProposal(_ p: PlanProposal) {
  print("\(p.id)  \(p.title) in \(p.plan) \(p.source.text)".printable)
  for edit in p.edits {
    if let old = edit.old { print("  - \(oneLine(old, max: 200))".printable) }
    print("  + \(oneLine(edit.new, max: 200))".printable)
  }
}

/// `sb plan artifact read|rewrite|apply|reject|report <plan>`.
private func artifact(_ a: Args, _ words: [String]) {
  let usage = "usage: sb plan artifact read|rewrite|apply|reject|report <plan>"
  guard words.count >= 2 else { die(usage) }
  let command = words[0]
  let plan = words[1]
  var args: [String: JSON] = ["plan": .string(plan)]
  let op: String
  switch command {
  case "read", "apply", "reject":
    op = "plan-artifact-\(command)"
  case "rewrite":
    op = "plan-artifact-rewrite"
    if words.count > 2 { args["rows"] = .array(words.dropFirst(2).map(JSON.string)) }
  case "report":
    op = "plan-artifact-report"
    guard let kind = a.values["--kind"] else { die("plan artifact report needs --kind read|proposal|check|published") }
    args["kind"] = .string(kind)
    if let file = a.values["--file"] {
      args["file"] = .string(URL(fileURLWithPath: file).path)
    }
    if let version = a.values["--version"] { args["version"] = .string(version) }
  default:
    die(usage)
  }
  printPlanDocument(call(op, args, timeout: 300), json: a.json)
}

private func printPlanDocument(_ result: JSON, json: Bool) {
  if json { return printJSON(result) }
  let p = decode(result, as: PlanDocument.self)
  print("\(p.id)  \(p.source.text)".printable)
  if let group = p.group { print("  group:   \(group)") }
  if let session = p.session { print("  session: \(session)") }
  print(
    "  read:    \(p.read.map(ago) ?? "never")\(p.artifact?.stale == true ? " (the copy may be old. Run: sb plan artifact read \(p.id))" : "")"
  )
  if let error = p.error { print("  error:   \(oneLine(error, max: 200))".printable) }
  if let note = p.updateNote { print("  update:  \(oneLine(note, max: 200))".printable) }
  if let proposal = p.proposal { print("  pending: \(proposal.id) (sb plan apply|reject \(proposal.id))") }
  print("  links:   \(p.links.count) PRs, \(p.rows.count) rows")
  print(
    "  table:   \(p.statusBlock == nil ? "no \(Plans.startMarker) block" : "yes"), auto update \(p.autoUpdate ? "on" : "off")"
  )
  let summary = PlanSummary(p)
  printRows(summary, indent: "  ")
  if let proposal = summary.proposal { printProposal(proposal, plan: p.id, indent: "  ") }
}

private func printProposal(_ p: ArtifactProposal.Summary, plan: String, indent: String) {
  let state = p.state == .pending ? "sb plan artifact apply|reject \(plan)" : "publishing"
  print("\(indent)update:  \(p.rows.isEmpty ? "the status table" : "\(p.rows.count) rows") (\(state))")
  for line in p.diff { print("\(indent)  \(oneLine(line, max: 200))".printable) }
}

/// One line for the plan, then a line for each out-of-date row and each row
/// that can become a follow-up.
func printPlan(_ p: PlanSummary, indent: String) {
  var line =
    "\(indent)plan: \(p.id) \(p.source.text) (\(p.rows) rows, \(p.outOfDate.count) out of date, \(p.canFollowUp.count) to follow up)"
  if let error = p.error { line += ", error: \(oneLine(error, max: 120))" }
  if let proposal = p.update { line += ", update \(proposal) waits for apply or reject" }
  if let note = p.updateNote { line += ", \(oneLine(note, max: 120))" }
  if p.copyStale == true { line += ", copy may be old" }
  print(line.printable)
  printRows(p, indent: indent + "  ")
  if let proposal = p.proposal { printProposal(proposal, plan: p.id, indent: indent + "  ") }
}

private func printRows(_ p: PlanSummary, indent: String) {
  for row in p.outOfDate {
    let changed = row.prs.filter(\.advanced).map { "\($0.link.text) \($0.now?.rawValue ?? "")" }
    print("\(indent)out of date: \(oneLine(row.text, max: 160)) (\(changed.joined(separator: ", ")))".printable)
  }
  for row in p.canFollowUp {
    print(
      "\(indent)not started: \(oneLine(row.label, max: 160)) (sb plan followup \(p.id) \(shellWord(row.ref ?? row.text)))"
        .printable
    )
  }
}
