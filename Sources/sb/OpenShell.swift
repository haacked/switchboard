import Foundation
import SwitchboardCore

/// `sb open-shell [on|off]`.
func openShell(_ a: Args) {
  var args: [String: JSON] = [:]
  switch a.positional {
  case []: break
  case ["on"]: args["openShell"] = true
  case ["off"]: args["openShell"] = false
  default: die("open-shell takes on or off")
  }
  let result = call("open-shell", args)
  if a.json { return printJSON(result) }
  let on = result["openShell"]?.bool ?? true
  print(on ? "New sessions open a shell." : "New sessions open without a shell.")
  if !args.isEmpty { print("Sessions that already exist keep their shell.") }
}
