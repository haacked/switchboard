import Foundation
import SwitchboardCore

/// `sb decide <session>` lists the decisions of the session's item with the
/// answers so far. With a decision's number it answers that decision, and
/// `--submit` and `--discard` finish the list.
func decide(_ a: Args) {
  let id = a.session("decide")
  let session = JSON.string(id)
  if a.switches.contains("--submit") {
    var args: [String: JSON] = ["session": session]
    if a.switches.contains("--stale") { args["stale"] = true }
    let result = call("decision-submit", args)
    return a.json ? printJSON(result) : print(result["delivery"]?.string ?? "sent")
  }
  if a.switches.contains("--discard") {
    let result = call("decision-discard", ["session": session])
    return a.json ? printJSON(result) : print("Discarded the answers.")
  }
  let words = Array(a.positional.dropFirst())
  guard let first = words.first else {
    let result = call("decisions", ["session": session])
    return a.json ? printJSON(result) : printDecisions(decode(result, as: DecisionList.self))
  }
  guard let number = Int(first) else { die("decide takes a decision's number, then its answer") }
  var args: [String: JSON] = ["session": session, "number": .number(Double(number))]
  let key = words.dropFirst().joined(separator: " ")
  let text = a.values["--text"]
  let skip = a.switches.contains("--skip")
  guard [!key.isEmpty, text != nil, skip].filter({ $0 }).count == 1 else {
    die("answer decision \(number) with one of an option by number or label, --text, or --skip")
  }
  if let text {
    args["text"] = .string(text)
  } else if skip {
    args["skip"] = true
  } else {
    args["options"] = [.string(key)]
    // A pick-any decision takes several options separated by commas. A label that holds a comma still names its own
    // option.
    if key.contains(",") {
      let list = decode(call("decisions", ["session": session]), as: DecisionList.self)
      if let decision = list.decisions.first(where: { $0.number == number }), decision.multiSelect,
        (try? decision.labels([key])) == nil
      {
        args["options"] = .array(key.split(separator: ",").map { .string(String($0)) })
      }
    }
  }
  let result = call("decision-answer", args)
  if a.json { return printJSON(result) }
  let list = decode(result, as: DecisionList.self)
  let open = list.unanswered.map(String.init)
  print(
    "Answered decision \(number). \(open.isEmpty ? "Every decision has an answer." : "Unanswered: \(open.joined(separator: ", ")).")"
  )
}

/// Prints each decision with its options and its answer. The text comes from the session.
func printDecisions(_ list: DecisionList) {
  func out(_ line: String) { print(line.printable) }
  if list.stale { out("The session took a turn since these decisions. --submit needs --stale.") }
  for d in list.decisions {
    out("\(d.number). \(d.header): \(d.question)\(d.multiSelect ? " (pick any)" : "")")
    if let context = d.context { out("   \(oneLine(context, max: 300))") }
    for (i, o) in d.options.enumerated() {
      out("   \(i + 1)) \(o.label)\(o.recommended ? " (recommended)" : "")\(o.detail.map { ": \($0)" } ?? "")")
    }
    out("   Answer: \(list.answer(d.number).map { DecisionList.text(of: $0, for: d) } ?? "none yet")")
  }
  if !list.newer.isEmpty {
    out("The session's newer item has \(list.newer.count) other decisions. --discard drops these answers.")
  }
}
