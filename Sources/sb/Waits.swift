import Foundation
import SwitchboardCore

/// Claude Code sets CLAUDECODE=1 for the commands it runs. sbd starts the
/// panes without it, so a command typed in a session's shell counts as yours.
let author = ProcessInfo.processInfo.environment["CLAUDECODE"] == "1" ? Author.claude : Author.you

/// The flags of a typed wait and the request field that each one sets.
let waitFlags = [
  "--kind": "kind", "--target": "target", "--who": "who", "--env": "environment", "--service": "service",
  "--state": "state", "--until": "until", "--note": "note", "--then": "then",
]

/// `sb wait <session> <note>` sets a manual wait. With flags after the
/// session, or with no session inside one, it sets a typed wait, clears
/// waits, or resolves one.
func waitCommand(_ a: Args) {
  let resolve = a.values["--resolve"]
  let clearing = a.switches.contains("--clear") || resolve != nil
  let words = a.positional.dropFirst().joined(separator: " ")
  if !words.isEmpty && (clearing || a.values["--note"] != nil) { refuse(words, "wait") }
  if clearing {
    var extra: [String: JSON] = [:]
    if let id = a.values["--id"] { extra["wait"] = .string(id) }
    if let resolve { extra["outcome"] = .string(resolve) }
    return sessionCommand(resolve == nil ? "clear-wait" : "resolve-wait", a, extra: extra)
  }
  var args: [String: JSON] = [:]
  for (flag, key) in waitFlags {
    if let value = a.values[flag] { args[key] = .string(value) }
  }
  if !words.isEmpty { args["note"] = .string(words) }
  if args.isEmpty { die("wait needs a note, --kind, --clear, or --resolve") }
  guard let session = a.positional.first ?? ProcessInfo.processInfo.environment["SB_SESSION_ID"] else {
    die("wait needs a session")
  }
  args["session"] = .string(session)
  args["by"] = .string(author.rawValue)
  let result = call("wait", args)
  if a.json { printJSON(result) } else { printSession(summary(result)) }
}

/// `sb note <session> <text>` adds a note. `--rm <id>` removes one. With
/// neither, it lists the notes.
func noteCommand(_ a: Args) {
  let session = JSON.string(a.session("note"))
  let text = a.positional.dropFirst().joined(separator: " ")
  let result: JSON
  if let id = a.values["--rm"] {
    if !text.isEmpty { refuse(text, "note") }
    result = call("remove-note", ["session": session, "note": .string(id)])
  } else if !text.isEmpty {
    result = call("note", ["session": session, "text": .string(text), "by": .string(author.rawValue)])
  } else {
    result = call("get", ["session": session])
  }
  if a.json { return printJSON(result) }
  let notes = summary(result).notes
  if notes.isEmpty { print("No notes.") }
  for n in notes { print(noteLine(n)) }
}

/// Exits for words after the session that the command's flags leave no place for.
func refuse(_ words: String, _ command: String) -> Never {
  die("\(command) doesn't know what to do with \"\(words)\". Put text with spaces in quotes.")
}

func noteLine(_ n: Note) -> String { "\(n.id)  \(n.text) (\(n.by.rawValue), \(ago(n.t)))" }

func printWaitsAndNotes(_ s: SessionSummary) {
  for w in s.waits { print("  wait:    \(w.id)  \(w.line) (\(w.kind.rawValue), \(w.by.rawValue), \(ago(w.created)))") }
  for n in s.notes { print("  note:    \(noteLine(n))") }
}
