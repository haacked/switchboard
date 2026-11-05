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
  for c in item.callouts {
    out("   [\(c.kind.rawValue)] \(c.title)\(c.body.isEmpty ? "" : ": \(oneLine(c.body, max: 200))")")
  }
  for (i, o) in item.options.enumerated() {
    out("   \(i + 1)) \(o.label)\(o.recommended ? " (recommended)" : "")\(o.detail.map { ": \($0)" } ?? "")")
    // Clicking sends this text as you, so you read it first.
    out("      \(o.action == .reply ? "Sends what you give with --text" : o.effect)")
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
  // Everything after the session is the option's name, up to a --text.
  var words = Array(a.positional.dropFirst())
  var text = a.values["--text"]
  if let i = words.firstIndex(of: "--text") {
    guard i + 1 < words.count else { die("--text needs a value") }
    text = words[(i + 1)...].joined(separator: " ")
    words = Array(words[..<i])
  }
  let key = words.joined(separator: " ")
  if key.isEmpty { die("choose needs an option, by number or label") }
  // The item that the user is about to click, so a new one is not clicked by mistake.
  guard let item = summary(call("get", ["session": .string(id)])).triage else { die("\(id) needs nothing from you") }
  var args: [String: JSON] = ["session": .string(id), "option": .string(key), "ref": .string(item.ref)]
  if let text { args["text"] = .string(text) }
  // A choice can allow, answer, or merge, which `allow`, `answer`, and `merge` refuse inside Claude Code.
  if ProcessInfo.processInfo.environment["CLAUDECODE"] != nil { args["insideClaude"] = true }
  // A merge option waits up to two minutes for `gh pr merge`, as `sb merge` does.
  let result = call("choose", args, timeout: 180)
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

/// `sb summary set [session]` records the Inbox card that a session writes
/// for its turn, read as JSON on stdin. `sb summary help` prints the format.
func summaryCommand(_ a: Args) {
  switch a.positional.first {
  case "set":
    let env = ProcessInfo.processInfo.environment
    // A card's buttons send text as the user, so Claude in one session doesn't write another's card.
    if env["CLAUDECODE"] != nil, a.positional.count > 1 {
      die("inside Claude Code, summary set writes only this session's card. Leave out the session")
    }
    guard let session = a.positional.dropFirst().first ?? env["SB_SESSION_ID"] else {
      die("summary set needs a session, or SB_SESSION_ID, which Switchboard sets in its sessions")
    }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let card = try? JSONCoding.decoder.decode(JSON.self, from: input) else {
      die("summary set reads the card as JSON on stdin. See sb summary help")
    }
    let result = call("summary-set", ["session": .string(session), "card": card])
    if a.json { return printJSON(result) }
    let options = result["options"]?.int ?? 0
    let callouts = result["callouts"]?.int ?? 0
    print(
      "Recorded the summary with \(options) option\(options == 1 ? "" : "s") and \(callouts) callout\(callouts == 1 ? "" : "s")."
    )
    for line in result["dropped"]?.array ?? [] { print("Dropped \(line.string ?? "")".printable) }
  case "help", nil:
    print(TriageCard.instructions)
  default:
    die("summary takes set or help")
  }
}
