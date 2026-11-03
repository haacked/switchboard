import Foundation
import SwitchboardCore

func group(_ a: Args) {
  let words = Array(a.positional.dropFirst())
  let by = JSON.string(author.rawValue)
  switch a.positional.first {
  case "ls", "list", nil:
    let result = call("group-ls")
    if a.json { return printJSON(result) }
    printGroups(decode(result, as: GroupList.self))
  case "add":
    guard let name = words.first else { die("group add needs a name") }
    var args: [String: JSON] = [
      "name": .string(name), "sessions": .array(words.dropFirst().map(JSON.string)), "by": by,
    ]
    if let note = a.values["--note"] { args["note"] = .string(note) }
    printGroup(call("group-add", args), json: a.json)
  case "rm":
    guard let ref = words.first else { die("group rm needs a group") }
    let result = call("group-rm", ["group": .string(ref)])
    if a.json { return printJSON(result) }
    let ungrouped = result["ungrouped"]?.array?.count ?? 0
    print("removed \(result["removed"]?.string ?? ref); \(ungrouped) ungrouped")
  case "move", "mv":
    if words.isEmpty { die("group move needs a session") }
    var args: [String: JSON] = ["sessions": .array(words.map(JSON.string))]
    if a.switches.contains("--ungrouped") {
      args["ungrouped"] = true
    } else if let to = a.values["--to"] {
      args["group"] = .string(to)
    } else {
      die("group move needs --to <group> or --ungrouped")
    }
    let result = call("group-move", args)
    if a.json { return printJSON(result) }
    for s in decode(result, as: [SessionSummary].self) { print("\(s.id)  \(s.name)".printable) }
  case "note":
    guard let ref = words.first, words.count > 1 else { die("group note needs a group and text") }
    printGroup(
      call("group-note", ["group": .string(ref), "text": .string(words.dropFirst().joined(separator: " ")), "by": by]),
      json: a.json)
  case "suggest":
    if let id = a.values["--accept"] { return printGroup(call("group-suggest", ["accept": .string(id)]), json: a.json) }
    let result = call("group-suggest")
    if a.json { return printJSON(result) }
    let suggestions = decode(result, as: [GroupSuggestion].self)
    guard !suggestions.isEmpty else { return print("No suggestions.") }
    for s in suggestions {
      let action = s.group == nil ? "new group \(s.name)" : "join \(s.name)"
      print("\(s.id)  \(action): \(s.sessions.joined(separator: ", ")) (\(s.reason))".printable)
    }
    print("\nAccept one with: sb group suggest --accept <id>")
  default:
    die("usage: sb group ls|add|rm|move|note|suggest")
  }
}

private func printGroup(_ result: JSON, json: Bool) {
  if json { return printJSON(result) }
  let g = decode(result, as: GroupSummary.self)
  print("\(g.id)  \(g.name)  \(g.sessions.count == 1 ? "1 session" : "\(g.sessions.count) sessions")".printable)
}

private func printGroups(_ list: GroupList) {
  if list.groups.isEmpty && list.ungrouped.isEmpty {
    print("No groups. Add one with: sb group add <name> [<session>...]")
  }
  for g in list.groups {
    print("\(g.name)  (\(g.id))".printable)
    for note in g.notes { print("  note: \(oneLine(note.text, max: 200))".printable) }
    for p in g.plans ?? [] { printPlan(p, indent: "  ") }
    print(g.sessions.isEmpty ? "  no sessions" : "  " + g.sessions.joined(separator: " "))
  }
  if !list.ungrouped.isEmpty {
    if !list.groups.isEmpty { print("") }
    print(BoardRows.ungroupedTitle)
    print("  " + list.ungrouped.joined(separator: " "))
  }
}

/// Lists the group's targets, asks the user to confirm, then sends. Session
/// text can quote PR comments and logs that carry instructions, so Claude
/// can't fan out unless the user confirmed the list and Claude passed --yes.
func sendGroup(_ a: Args, group: String) {
  let text = a.positional.joined(separator: " ")
  if text.isEmpty { die("send needs text") }
  var args: [String: JSON] = ["group": .string(group), "text": .string(text)]
  if author == .claude, let from = ProcessInfo.processInfo.environment["SB_SESSION_ID"] { args["from"] = .string(from) }
  let preview = decode(call("send-group", args), as: GroupSend.self)
  if preview.targets.isEmpty { die("\(group) has no session to send to") }
  let list = preview.targets.map { "  \($0.id)  \($0.name)".printable }.joined(separator: "\n")
  let count = preview.targets.count == 1 ? "this session" : "these \(preview.targets.count) sessions"
  if !a.switches.contains("--yes") {
    if author == .claude {
      die(
        "a message to a group needs the user's confirmation. Show the user this list, and pass --yes only after they confirm it:\n\(list)"
      )
    }
    guard isatty(STDIN_FILENO) != 0 else { die("pass --yes to send to \(count) without asking:\n\(list)") }
    print("Send to \(count)?\n\(list)\n[y/N] ", terminator: "")
    guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else { die("not sent") }
  }
  args["confirmed"] = true
  args["targets"] = .array(preview.targets.map { .string($0.id) })
  let result = call("send-group", args)
  if a.json { return printJSON(result) }
  for d in decode(result, as: GroupSend.self).deliveries ?? [] {
    print("\(d.session)  \(d.delivery?.rawValue ?? "failed: \(d.error ?? "")")".printable)
  }
}
