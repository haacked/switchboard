import Foundation
import SwitchboardCore

/// Prints an item: its title, then its Summary, its Action, and a line that names what its Details hold.
func printTriage(_ s: SessionSummary, position: Int? = nil) {
  guard let item = s.triage else { return }
  func out(_ line: String) { print(line.printable) }
  let number = position.map { "\($0). " } ?? ""
  out("\(number)\(item.title)  [\(item.kind.rawValue)]")
  let folder = s.repoFolder.map { ($0 as NSString).lastPathComponent + ", " } ?? ""
  out("   \(sessionMention(name: s.name, id: s.id)), \(folder)\(ago(s.since))")
  out("   Summary:")
  if !item.summary.isEmpty { out("      \(oneLine(item.summary, max: 300))") }
  for c in item.callouts {
    out("      [\(c.kind.rawValue)] \(c.title)\(c.body.isEmpty ? "" : ": \(oneLine(c.body, max: 200))")")
  }
  for draft in item.drafts {
    out("   Draft\(draft.label.map { ": \($0)" } ?? ""):")
    for line in draft.text.split(separator: "\n", omittingEmptySubsequences: false) { out("      > \(line)") }
  }
  out("   Action:")
  if item.hasTickable {
    out("      pick any, as in: sb choose \(s.id) 1,3")
  }
  // The same condition that `sb decide` and the app's step view use.
  let list = s.shownDecisions
  if let list { out("      \(list.decisions.count) decisions, answered one at a time: sb decide \(s.id)") }
  if item.options.isEmpty && list == nil {
    // A held card with several questions has no options. `sb ack` would hide its blocked turn.
    out(
      item.source == .card
        ? "      answer the questions: sb answer \(s.id) <answer>..."
        : "      none, except Acknowledge: sb ack \(s.id)")
  }
  for (i, o) in item.options.enumerated() {
    out("   " + optionLine(i + 1, o.label, recommended: o.recommended, detail: o.detail))
    // Clicking sends this text as you, so you read it first.
    out("         \(o.action == .reply ? "Sends what you give with --text" : o.effect(mergeMethod: s.pr?.mergeMethod))")
  }
  let held = item.details.parts
  out("   Details: \(held.isEmpty ? "none" : held.joined(separator: ", ")) (sb get --json \(s.id))")
}

/// An option as `sb triage` and `sb decide` list it, under its item.
func optionLine(_ number: Int, _ label: String, recommended: Bool, detail: String?) -> String {
  "   \(number)) \(label)\(recommended ? " (recommended)" : "")\(detail.map { ": \($0)" } ?? "")"
}

/// The options that a key separated by commas names, each trimmed.
func commaKeys(_ key: String) -> JSON {
  .array(key.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
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
  var args: [String: JSON] = ["session": .string(id), "ref": .string(item.ref)]
  // A multi-select card takes several options separated by commas, as `sb answer` does.
  // A label that holds a comma still names its own option.
  if item.multiSelect, key.contains(","), (try? item.option(key)) == nil {
    args["options"] = commaKeys(key)
  } else {
    args["option"] = .string(key)
  }
  if let text { args["text"] = .string(text) }
  // A choice can allow, answer, merge, or request a review. `allow`, `answer`, `merge`, and `review` refuse those
  // inside Claude Code.
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
    let decisions = result["decisions"]?.int ?? 0
    let drafts = result["drafts"]?.int ?? 0
    let counts = [
      "\(options) option\(options == 1 ? "" : "s")", "\(callouts) callout\(callouts == 1 ? "" : "s")",
      decisions == 0 ? nil : "\(decisions) decision\(decisions == 1 ? "" : "s")",
      drafts == 0 ? nil : "\(drafts) draft\(drafts == 1 ? "" : "s")",
    ]
    print("Recorded the summary with \(englishList(counts.compactMap { $0 })).")
    for line in result["dropped"]?.array ?? [] { print("Dropped \(line.string ?? "")".printable) }
  case "help", nil:
    print(TriageCard.instructions)
  default:
    die("summary takes set or help")
  }
}
