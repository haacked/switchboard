import Foundation
import SwitchboardCore

func spawn(_ a: Args) {
  var args: [String: JSON] = [:]
  if let repo = a.values["--repo"] {
    // sbd runs in another folder. The CLI sends a path as an absolute one.
    let isPath = ["/", "~", "."].contains { repo.hasPrefix($0) }
    args["repository"] = .string(isPath ? URL(fileURLWithPath: repo.expandingTilde).standardizedFileURL.path : repo)
  }
  let flags = [
    "--branch": "branch", "--prompt": "prompt", "--after": "after", "--name": "name", "--base": "base",
    "--model": "model", "--account": "account",
  ]
  for (flag, key) in flags {
    if let value = a.values[flag] { args[key] = .string(value) }
  }
  if a.switches.contains("--followup") { args["followup"] = .bool(true) }
  if author == .claude, let parent = ProcessInfo.processInfo.environment["SB_SESSION_ID"] {
    args["parent"] = .string(parent)
  }
  let result = call("spawn", args, timeout: 300)
  if a.json { printJSON(result) } else { printSession(summary(result)) }
}
