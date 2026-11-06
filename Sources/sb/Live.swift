import Foundation
import SwitchboardCore

/// `sb live [--set N]`.
func live(_ a: Args) {
  var args: [String: JSON] = [:]
  if let value = a.values["--set"] {
    guard let cap = Int(value), cap >= 1 else { die("--set takes a whole number of at least 1") }
    args["cap"] = .number(Double(cap))
  }
  let result = call("live", args)
  if a.json {
    printJSON(result)
    return
  }
  let status = decode(result, as: LiveStatus.self)
  print("\(status.live.count) of \(status.cap) claude processes live, \(status.queued.count) queued")
  for s in status.live {
    print("  \(s.name)  \(s.pid.map { "pid \($0)" } ?? "starting")  \(s.state.title)".printable)
  }
  for s in status.queued {
    print("  \(s.name)  queued \(ago(s.since)) ago".printable)
  }
}
