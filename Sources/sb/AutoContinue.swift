import Foundation
import SwitchboardCore

/// `sb autocontinue [on|off|status]`.
func autoContinue(_ a: Args) {
  var args: [String: JSON] = [:]
  switch a.positional.first ?? "status" {
  case "on": args["enabled"] = true
  case "off": args["enabled"] = false
  case "status": break
  default: die("autocontinue takes on, off, or status")
  }
  let result = call("autocontinue", args)
  if a.json {
    printJSON(result)
    return
  }
  let status = decode(result, as: AutoContinueStatus.self)
  print("auto-continue is \(status.enabled ? "on" : "off")")
  let running = status.liveCap.map { "\(status.live) of \($0)" } ?? "\(status.live)"
  print(
    "sends \"\(status.message)\" after \(status.quietSeconds) s untouched, at most \(status.perHour) times an hour per session, with \(running) claude processes running"
      .printable)
  for s in status.sessions {
    print("\(s.name)  \(s.blocker ?? (status.enabled ? "continues on the next tick" : "would continue"))".printable)
  }
}
