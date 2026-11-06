import Foundation
import SwitchboardCore

/// `sb live [--set N | --unlimited]`.
func live(_ a: Args) {
  var args: [String: JSON] = [:]
  if a.switches.contains("--unlimited") {
    if a.values["--set"] != nil { die("--set and --unlimited can't be used together") }
    args["unlimited"] = true
  } else if let value = a.values["--set"] {
    guard let cap = Int(value), cap >= 1 else { die("--set takes a whole number of at least 1") }
    args["cap"] = .number(Double(cap))
  }
  let result = call("live", args)
  if a.json {
    printJSON(result)
    return
  }
  let status = decode(result, as: LiveStatus.self)
  if let cap = status.cap {
    print("\(status.live.count) of \(cap) claude processes running, \(status.queued.count) held")
  } else {
    print("\(status.live.count) claude processes running, no limit")
  }
  for s in status.live {
    print("  \(s.name)  \(s.pid.map { "pid \($0)" } ?? "starting")  \(s.state.title)".printable)
  }
  for s in status.queued {
    print("  \(s.name)  held \(ago(s.since)) ago".printable)
  }
}
