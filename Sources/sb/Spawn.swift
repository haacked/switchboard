import Foundation
import SwitchboardCore

/// The request's `planMode` for `--plan-mode`.
func planMode(_ a: Args) -> Bool? {
  a.switches.contains("--plan-mode") ? true : nil
}

func spawn(_ a: Args) {
  var args: [String: JSON] = [:]
  // A path on a host is passed as typed, and the host resolves its ~. On a host, a --repo that starts with . is
  // joined to the host's folder, because any other relative value names a repository.
  if let repo = a.values["--repo"] {
    let path: String
    if let cwd = cliCwd {
      path = repo.hasPrefix(".") ? SessionHost.hostFolder(repo, cwd: cwd) : repo
    } else {
      path = SessionHost.namesRemote(a.values["--host"]) ? repo : repo.repositoryArgument
    }
    args["repository"] = .string(path)
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
  if let planMode = planMode(a) { args["planMode"] = .bool(planMode) }
  if author == .claude, let parent = ProcessInfo.processInfo.environment["SB_SESSION_ID"] {
    args["parent"] = .string(parent)
  }
  let result = call("spawn", args, timeout: 300)
  if a.json { printJSON(result) } else { printSession(summary(result)) }
}
