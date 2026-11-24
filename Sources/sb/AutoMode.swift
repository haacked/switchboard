import Foundation
import SwitchboardCore

/// `sb auto-mode [on|off]`.
func autoMode(_ a: Args) {
  var args: [String: JSON] = [:]
  switch a.positional {
  case []: break
  case ["on"]: args["autoMode"] = true
  case ["off"]: args["autoMode"] = false
  default: die("auto-mode takes on or off")
  }
  if !args.isEmpty {
    // A session that read injected instructions could otherwise start every new session without permission prompts.
    refuseInsideClaudeCode("auto-mode on|off needs the user, so it doesn't run inside Claude Code")
  }
  let result = call("auto-mode", args)
  if a.json { return printJSON(result) }
  let on = result["autoMode"]?.bool ?? false
  print(on ? "New sessions start in auto mode." : "New sessions start without auto mode.")
  if !args.isEmpty { print("Sessions that already exist keep their mode.") }
}
