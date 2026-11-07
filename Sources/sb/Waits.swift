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

/// `sb note <session> <text>` adds a note, and `--todo` makes it a to-do.
/// `--rm <id>` removes one, and `--resolve <id>` resolves a to-do. With none
/// of them, it lists the notes. `sb note --resolved` lists the resolved to-dos.
func noteCommand(_ a: Args) {
  if a.switches.contains("--resolved") { return resolvedTodosCommand(a) }
  let session = JSON.string(a.session("note"))
  let text = a.positional.dropFirst().joined(separator: " ")
  let result: JSON
  if let id = a.values["--rm"] {
    if !text.isEmpty { refuse(text, "note") }
    result = call("remove-note", ["session": session, "note": .string(id)])
  } else if let id = a.values["--resolve"] {
    if !text.isEmpty { refuse(text, "note") }
    result = call("resolve-note", ["session": session, "note": .string(id), "by": .string(author.rawValue)])
  } else if !text.isEmpty {
    var args: [String: JSON] = ["session": session, "text": .string(text), "by": .string(author.rawValue)]
    if a.switches.contains("--todo") { args["kind"] = .string(Note.Kind.todo.rawValue) }
    result = call("note", args)
  } else {
    if a.switches.contains("--todo") { die("note --todo needs text") }
    result = call("get", ["session": session])
  }
  if a.json { return printJSON(result) }
  let notes = summary(result).notes
  if notes.isEmpty { print("No notes.") }
  for n in listOrder(notes) { print(noteLine(n)) }
}

/// `sb note --resolved [--limit N]` lists the records of resolved to-dos, newest first.
func resolvedTodosCommand(_ a: Args) {
  var args: [String: JSON] = [:]
  if let limit = a.values["--limit"] {
    guard let n = Int(limit) else { die("--limit needs a whole number") }
    args["limit"] = .number(Double(n))
  }
  let result = call("resolved-todos", args)
  if a.json { return printJSON(result) }
  let rows = decode(result, as: [ResolvedTodo].self)
  if rows.isEmpty { print("No resolved to-dos.") }
  for r in rows {
    print("\(r.note)  \(r.text) (\(r.how) \(ago(r.resolved)); \(r.session) \(r.name))".printable)
  }
}

/// Sets `resolve` to the --resolve ids and `by` to the author. sbd refuses
/// the removal for Claude. Only you resolve a to-do.
func addResolveFlags(_ a: Args, to args: inout [String: JSON]) {
  guard let ids = a.allValues["--resolve"] else { return }
  args["resolve"] = .array(ids.map(JSON.string))
  args["by"] = .string(author.rawValue)
}

/// Exits for words after the session that the command's flags leave no place for.
func refuse(_ words: String, _ command: String) -> Never {
  die("\(command) doesn't know what to do with \"\(words)\". Put text with spaces in quotes.")
}

func noteLine(_ n: Note) -> String {
  var kind = ""
  if n.kind == .todo { kind = n.resolved.map { "to-do, resolved \(ago($0.t)); " } ?? "to-do, " }
  return "\(n.id)  \(n.text) (\(kind)\(n.by.rawValue), \(ago(n.t)))".printable
}

/// The open to-dos first, then the plain notes, then the resolved to-dos.
func listOrder(_ notes: [Note]) -> [Note] { notes.openTodos + notes.plainNotes + notes.resolvedTodos }

func printWaitsAndNotes(_ s: SessionSummary) {
  for w in s.waits { print("  wait:    \(w.id)  \(w.line) (\(w.kind.rawValue), \(w.by.rawValue), \(ago(w.created)))") }
  for n in listOrder(s.notes) { print("  note:    \(noteLine(n))") }
}
