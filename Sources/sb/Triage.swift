import Foundation
import SwitchboardCore

/// Prints an item: its title, what the session says, and its options.
func printTriage(_ s: SessionSummary, position: Int? = nil) {
  guard let item = s.triage else { return }
  func out(_ line: String) { print(line.printable) }
  let number = position.map { "\($0). " } ?? ""
  out("\(number)\(item.title)  [\(item.kind.rawValue)]")
  out("   \(s.name) (\(s.id)), \(s.repo.map { ($0 as NSString).lastPathComponent + ", " } ?? "")\(ago(s.since))")
  if !item.summary.isEmpty { out("   \(oneLine(item.summary, max: 300))") }
  for (i, o) in item.options.enumerated() {
    out("   \(i + 1)) \(o.label)\(o.recommended ? " (recommended)" : "")\(o.detail.map { ": \($0)" } ?? "")")
    // Clicking sends this text as you, so you read it first.
    if item.source != .card && o.message != o.label { out("      sends: \(oneLine(o.message, max: 200))") }
  }
}

/// `sb triage` lists the sessions that need you or that Claude can continue,
/// in the order to go through them.
func triage(_ a: Args) {
  let result = call("triage")
  if a.json { return printJSON(result) }
  let list = decode(result, as: [SessionSummary].self)
  if list.isEmpty { return print("Nothing needs you.") }
  for (i, s) in list.enumerated() {
    if i > 0 { print("") }
    printTriage(s, position: i + 1)
  }
}

/// `sb next` prints the first item of the triage list.
func next(_ a: Args) {
  let first = decode(call("triage"), as: [SessionSummary].self).first
  if a.json { return printJSON(first.flatMap { try? JSON(encoding: $0) } ?? .null) }
  guard let first else { return print("Nothing needs you.") }
  printTriage(first)
}

/// `sb choose <session> <option>` does what a click on the option does.
func choose(_ a: Args) {
  let id = a.session("choose")
  let key = a.positional.dropFirst().joined(separator: " ")
  if key.isEmpty { die("choose needs an option, by number or label") }
  // The item that the user is about to click, so a new one is not clicked by mistake.
  guard let item = summary(call("get", ["session": .string(id)])).triage else { die("\(id) needs nothing from you") }
  var args: [String: JSON] = ["session": .string(id), "option": .string(key), "ref": .string(item.ref)]
  // Choosing on a card allows or answers it, which `allow` and `answer` refuse inside Claude Code.
  if ProcessInfo.processInfo.environment["CLAUDECODE"] != nil { args["refuseCards"] = true }
  let result = call("choose", args)
  if a.json { printJSON(result) } else { print(result["delivery"]?.string ?? "answered") }
}

/// `sb reply <session>` prints the session's last reply as Markdown.
func replyCommand(_ a: Args) {
  let result = call("reply", ["session": .string(a.session("reply"))])
  if a.json { printJSON(result) } else { print(controlsEscaped(result["reply"]?.string ?? "")) }
}

/// The text with each control character but newline and tab shown as an
/// escape, so that a reply can't drive the terminal.
func controlsEscaped(_ text: String) -> String {
  text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.printable }.joined(separator: "\n")
}
