import Foundation
import SwitchboardCore

func followup(_ a: Args) {
  let words = a.positional.dropFirst()
  switch a.positional.first {
  case "add":
    let text = words.joined(separator: " ")
    if text.isEmpty { die("followup add needs text") }
    var args: [String: JSON] = ["prompt": .string(text)]
    let flags = [
      "--title": "title", "--repo": "repository", "--branch": "branch", "--on": "on", "--after": "after",
      "--link": "link", "--model": "model", "--account": "account",
    ]
    for (flag, key) in flags {
      if let value = a.values[flag] { args[key] = .string(value) }
    }
    if a.values["--repo"] == nil { args["cwd"] = .string(FileManager.default.currentDirectoryPath) }
    // A follow-up added inside a session records that session as its parent.
    if let parent = a.values["--parent"] ?? ProcessInfo.processInfo.environment["SB_SESSION_ID"] {
      args["parent"] = .string(parent)
    }
    let result = call("followup-add", args)
    if a.json { printJSON(result) } else { printSession(summary(result)) }
  case "ls", "list":
    let result = call("followup-ls")
    if a.json {
      printJSON(result)
    } else {
      let list = decode(result, as: [SessionSummary].self)
      if list.isEmpty { print("No follow-ups. Add one with: sb followup add <text>") } else { printTable(list) }
    }
  case "start":
    var args: [String: JSON] = ["session": .string(followupRef(a, "start"))]
    if let path = a.values["--path"] { args["path"] = .string(URL(fileURLWithPath: path.expandingTilde).path) }
    if let branch = a.values["--branch"] { args["branch"] = .string(branch) }
    if let base = a.values["--base"] { args["base"] = .string(base) }
    let result = call("followup-start", args, timeout: 300)
    if a.json { printJSON(result) } else { printSession(summary(result)) }
  case "rm":
    let result = call("followup-rm", ["session": .string(followupRef(a, "rm"))])
    if a.json { printJSON(result) } else { print("removed \(result["removed"]?.string ?? "")") }
  case "import":
    let file = a.values["--file"].map { URL(fileURLWithPath: $0.expandingTilde).path }
    let result = call("followup-import", file.map { ["file": .string($0)] } ?? [:])
    if a.json {
      printJSON(result)
    } else {
      let count = result["imported"]?.array?.count ?? 0
      print("Imported \(count == 1 ? "1 follow-up" : "\(count) follow-ups") from \(result["file"]?.string ?? "").")
      if let skipped = result["skipped"]?.int, skipped > 0 {
        print("Skipped \(skipped == 1 ? "1 line" : "\(skipped) lines") that an earlier import read.")
      }
    }
  default:
    die("usage: sb followup add|ls|start|rm|import")
  }
}

/// Prints the sessions by state, and how many follow-ups haven't started,
/// which `ls` leaves out. An older sbd without `followup-ls` prints no count.
func printSessionList(_ sessions: [SessionSummary]) {
  printTable(sessions)
  let listed = try? client.call("followup-ls", as: [SessionSummary].self)
  let followups = (listed ?? []).filter { $0.state == .notStarted }.count
  if followups > 0 {
    print(
      "\n\(followups) \(followups == 1 ? "follow-up hasn't" : "follow-ups haven't") started. sb followup ls lists them."
    )
  }
}

/// The lines of `sb get` for a follow-up that hasn't started, after its name and state.
func printFollowup(_ s: SessionSummary) {
  guard let f = s.followup else { return }
  print("  repository: \(f.repository.map { $0 + (f.sourceBranch.map { " · \($0)" } ?? "") } ?? "none")")
  if let branch = s.branch { print("  branch:  \(branch)") }
  if let link = f.link { print("  link:    \(link)") }
  if let parent = s.parent { print("  parent:  \(parent)") }
  print("  prompt:  \(f.prompt)".printable)
}

func followupRef(_ a: Args, _ command: String) -> String {
  guard a.positional.count > 1 else { die("followup \(command) needs a follow-up") }
  return a.positional[1]
}
