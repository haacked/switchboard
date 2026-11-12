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
    print("No permission prompts, questions, group messages, or folder trust prompts are open.")
    return
  }
  // Claude chose this text, so control characters print as escapes.
  func out(_ line: String) { print(line.printable) }
  for (name, card) in cards {
    let head =
      "\(card.id)  \(name) (\(card.session))  \(ago(card.since))\(card.deferred ? ", deferred" : "")\(card.hookClosed ? ", hook closed" : "")"
    if card.kind == .permission {
      // `allow` approves the whole call, so the whole call prints.
      out("\(head)  approve \(card.tool)\(card.offersAutoMode ? ", --auto offered" : "")")
      for line in card.details.split(separator: "\n", omittingEmptySubsequences: false) { out("      \(line)") }
      continue
    }
    if card.kind == .trust {
      out("\(head)  trust \(card.summary)")
      out("      allow trusts the folder, deny exits claude")
      continue
    }
    if let message = card.send {
      // `allow` sends exactly this text to exactly these sessions, so both print in full.
      out("\(head)  send \(message.summary)")
      for t in message.targets { out("      to \(t.id)  \(t.name)") }
      for line in message.text.split(separator: "\n", omittingEmptySubsequences: false) { out("      | \(line)") }
      continue
    }
    out("\(head)  question")
    for q in card.questions {
      out("      \(q.header.map { "\($0): " } ?? "")\(q.question)\(q.multiSelect ? " (pick any)" : "")")
      for o in q.options { out("        \(o.label)\(o.description.map { ": \($0)" } ?? "")") }
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
    if a.switches.contains("--auto") { args["autoMode"] = true }
  case "deny":
    args["behavior"] = "deny"
    if !words.isEmpty { args["message"] = .string(words.joined(separator: " ")) }
  default:
    if words.isEmpty { die("answer needs an answer for each question") }
    args["answers"] = .array(words.map(JSON.string))
  }
  let result = call("answer", args)
  if a.json { return printJSON(result) }
  if result["decision"] != nil {
    let sent = decode(result, as: GroupSend.self)
    print(sent.decision?.rawValue ?? "")
    return printDeliveries(sent)
  }
  print(result["delivery"]?.string ?? "answered")
}
