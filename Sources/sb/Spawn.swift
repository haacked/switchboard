import Foundation
import SwitchboardCore

func spawn(_ a: Args) {
  var args: [String: JSON] = [:]
  // A path on a host is passed as typed, and the host resolves its ~.
  if let repo = a.values["--repo"] {
    args["repository"] = .string(SessionHost.namesRemote(a.values["--host"]) ? repo : repo.repositoryArgument)
  }
  let flags = [
    "--branch": "branch", "--prompt": "prompt", "--after": "after", "--name": "name", "--base": "base",
    "--model": "model", "--account": "account", "--wait": "wait", "--host": "host",
  ]
  for (flag, key) in flags {
    if let value = a.values[flag] { args[key] = .string(value) }
  }
  if a.switches.contains("--followup") { args["followup"] = .bool(true) }
  if a.switches.contains("--no-auto") { args["autoMode"] = .bool(false) }
  if author == .claude, let parent = ProcessInfo.processInfo.environment["SB_SESSION_ID"] {
    args["parent"] = .string(parent)
  }
  let result = call("spawn", args, timeout: 300)
  if a.json { printJSON(result) } else { printSession(summary(result)) }
}
