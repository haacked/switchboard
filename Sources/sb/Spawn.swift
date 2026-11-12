import Foundation
import SwitchboardCore

/// The request's `planMode` for `--plan-mode`. `Args` reads `--plan` as a
/// valued flag. `--plan --prompt P` would then swallow the prompt, so `new`
/// and `spawn` refuse `--plan`.
func planMode(_ a: Args) -> Bool? {
  if a.values["--plan"] != nil { die("use --plan-mode to start in plan mode. --plan names a plan document") }
  return a.switches.contains("--plan-mode") ? true : nil
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
