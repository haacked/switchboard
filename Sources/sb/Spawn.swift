import Foundation
import SwitchboardCore

/// The request's `planMode` for `--plan-mode`.
func planMode(_ a: Args) -> Bool? {
  a.switches.contains("--plan-mode") ? true : nil
}

func spawn(_ a: Args) {
  var args: [String: JSON] = [:]
  if let repo = a.values["--repo"] { args["repository"] = .string(repo.repositoryArgument) }
  let flags = [
    "--branch": "branch", "--prompt": "prompt", "--after": "after", "--name": "name", "--base": "base",
    "--model": "model", "--account": "account", "--wait": "wait",
  ]
  for (flag, key) in flags {
    if let value = a.values[flag] { args[key] = .string(value) }
  }
  if a.switches.contains("--followup") { args["followup"] = .bool(true) }
  if a.switches.contains("--no-auto") { args["autoMode"] = .bool(false) }
  if let planMode = planMode(a) { args["planMode"] = .bool(planMode) }
  if author == .claude, let parent = ProcessInfo.processInfo.environment["SB_SESSION_ID"] {
    args["parent"] = .string(parent)
  }
  let result = call("spawn", args, timeout: 300)
  if a.json { printJSON(result) } else { printSession(summary(result)) }
}
