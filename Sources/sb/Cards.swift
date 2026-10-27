import Foundation
import SwitchboardCore

/// Lists the open cards of every session, or of one, oldest first.
func cards(_ a: Args) {
  let sessions =
    a.positional.first.map { [summary(call("get", ["session": .string($0)]))] }
    ?? decode(call("ls"), as: [SessionSummary].self)
  let cards = sessions.flatMap { s in s.cards.map { (name: s.name, card: $0) } }.sorted { $0.card.since < $1.card.since }
  if a.json {
    printJSON((try? JSON(encoding: cards.map(\.card))) ?? .null)
    return
  }
  if cards.isEmpty {
    print("No permission prompts or questions are open.")
    return
  }
  for (name, card) in cards {
    let head = "\(card.id)  \(name) (\(card.session))  \(ago(card.since))\(card.deferred ? ", deferred" : "")"
    if card.kind == .permission {
      print("\(head)  approve \(card.summary)")
      continue
    }
    print("\(head)  question")
    for q in card.questions {
      print("      \(q.header.map { "\($0): " } ?? "")\(q.question)\(q.multiSelect ? " (pick any)" : "")")
      for o in q.options {
        print("        \(o.label)\(o.description.map { ": \($0)" } ?? "")")
      }
    }
  }
}

/// Runs `allow`, `deny`, and `answer`, which answer a session's card.
func answer(_ command: String, _ a: Args) {
  var args: [String: JSON] = ["session": .string(a.session(command))]
  if let card = a.values["--card"] {
    guard let n = Int(card) else { die("--card needs a card number") }
    args["card"] = .number(Double(n))
  }
  let words = Array(a.positional.dropFirst())
  switch command {
  case "allow":
    args["behavior"] = "allow"
  case "deny":
    args["behavior"] = "deny"
    if !words.isEmpty { args["message"] = .string(words.joined(separator: " ")) }
  default:
    if words.isEmpty { die("answer needs an answer for each question") }
    args["answers"] = .array(words.map(JSON.string))
  }
  let result = call("answer", args)
  if a.json { printJSON(result) } else { print(result["delivery"]?.string ?? "answered") }
}
