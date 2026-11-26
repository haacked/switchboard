import Foundation
import SwitchboardCore

/// Lists the open cards of every session, or of one, oldest first.
func cards(_ a: Args) {
  let sessions =
    a.positional.first.map { [summary(call("get", ["session": .string($0)]))] }
    ?? decode(call("ls"), as: [SessionSummary].self)
  let cards = sessions.flatMap { s in s.cards.map { (name: s.name, card: $0) } }.sorted {
    $0.card.since < $1.card.since
  }
  if a.json {
    printJSON((try? JSON(encoding: cards.map(\.card))) ?? .null)
    return
  }
  if cards.isEmpty {
    print(
      "No permission prompts, questions, group messages, folder trust prompts, MCP server requests, or script proposals are open."
    )
    return
  }
  // Claude chose this text, so control characters print as escapes.
  func out(_ line: String) { print(line.printable) }
  for (name, card) in cards {
    let head =
      "\(card.id)  \(sessionMention(name: name, id: card.session))  \(ago(card.since))\(card.deferred ? ", deferred" : "")\(card.hookClosed ? ", hook closed" : "")"
    switch card.kind {
    case .permission:
      // `allow` approves the whole call, so the whole call prints.
      let extras = card.offeredExtras
      out("\(head)  approve \(card.tool)\(extras.map { ", \($0.flag) offered" }.joined())")
      for line in card.details.split(separator: "\n", omittingEmptySubsequences: false) { out("      \(line)") }
      for extra in extras {
        if let note = card.note(extra) { out("      \(extra.flag): \(note)") }
      }
    case .trust:
      out("\(head)  trust \(card.summary)")
      out("      allow trusts the folder, deny exits claude")
    case .send:
      // `allow` sends exactly this text to exactly these sessions, so both print in full.
      out("\(head)  send \(card.summary)")
      for t in card.send?.targets ?? [] { out("      to \(t.id)  \(t.name)") }
      for line in (card.send?.text ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
        out("      | \(line)")
      }
    case .mcp:
      out("\(head)  \(card.summary)")
      out("      reason: \(card.mcpRequest?.reason ?? "")")
      out("      allow restarts claude with it, deny leaves the servers as they are")
    case .script:
      // `allow` stores exactly this command for exactly this session, so both print in full.
      guard let p = card.scriptProposal?.value else { break }
      out("\(head)  \(p.schedule.map { "change schedule \($0) to run a script" } ?? "run a script")")
      out("      in \(p.targetName) (\(p.target))  \(p.folder)")
      out("      \(p.timingText)")
      for line in p.command.split(separator: "\n", omittingEmptySubsequences: false) { out("      $ \(line)") }
      if let before = p.before {
        for line in before.command.split(separator: "\n", omittingEmptySubsequences: false) {
          out("      was: \(line)")
        }
      }
      if !p.reason.isEmpty { out("      reason: \(p.reason)") }
      out("      \(ScriptProposal.worktreeNote)")
      out("      allow stores the schedule, deny drops it")
    case .question:
      out("\(head)  question")
      for q in card.questions {
        out("      \(q.header.map { "\($0): " } ?? "")\(q.question)\(q.multiSelect ? " (pick any)" : "")")
        for o in q.options { out("        \(o.label)\(o.description.map { ": \($0)" } ?? "")") }
      }
    }
  }
}

/// Runs `allow`, `deny`, and `answer`, which answer a session's card.
func answer(_ command: String, _ a: Args) {
  // A session that read injected instructions could otherwise approve its
  // own or another session's tool calls.
  if ProcessInfo.processInfo.environment["CLAUDECODE"] != nil {
    die("\(command) answers for you, so it doesn't run inside Claude Code")
  }
  var args: [String: JSON] = ["session": .string(a.session(command))]
  if let card = a.values["--card"] {
    guard let n = Int(card) else { die("--card needs a card number") }
    args["card"] = .number(Double(n))
  }
  let words = Array(a.positional.dropFirst())
  switch command {
  case "allow":
    args["behavior"] = "allow"
    for extra in AllowExtra.allCases where a.switches.contains(extra.flag) { args[extra.argument] = true }
  case "deny":
    args["behavior"] = "deny"
    if !words.isEmpty { args["message"] = .string(words.joined(separator: " ")) }
  default:
    if words.isEmpty { die("answer needs an answer for each question") }
    args["answers"] = .array(words.map(JSON.string))
  }
  let result = call("answer", args)
  if a.json { return printJSON(result) }
  if result["targets"] != nil {
    let sent = decode(result, as: GroupSend.self)
    print(sent.decision?.rawValue ?? "")
    return printDeliveries(sent)
  }
  if result["reason"] != nil {
    let status = decode(result, as: MCPServerRequestStatus.self)
    return print("\(status.decision.rawValue). \(status.name): \(Manager.serversText(status.loaded))".printable)
  }
  if result["pending"] != nil {
    let status = decode(result, as: ScriptProposalStatus.self)
    return print("\(status.decision.rawValue)\(status.schedule.map { ": schedule \($0)" } ?? "")")
  }
  print(result["delivery"]?.string ?? "answered")
}
