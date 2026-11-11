import Foundation
import SwitchboardCore

/// `sb host [ls]` lists the remote hosts and their ssh links. `sb host connect <host>` and
/// `sb host disconnect <host>` open and close one link and print the host's row.
func host(_ a: Args) {
  let verb = a.positional.first ?? "ls"
  switch verb {
  case "ls":
    let result = call("hosts")
    if a.json {
      printJSON(result)
      return
    }
    let hosts = decode(result, as: [HostStatus].self)
    if hosts.isEmpty {
      print("No hosts. Add them under hosts in \(client.home.config).")
      return
    }
    printHosts(hosts)
  case "connect", "disconnect":
    guard a.positional.count > 1 else { die("host \(verb) needs a host") }
    let result = call("host-\(verb)", ["host": .string(a.positional[1])])
    if a.json {
      printJSON(result)
      return
    }
    printHosts([decode(result, as: HostStatus.self)])
  default:
    die("unknown host command \(verb). Use ls, connect, or disconnect")
  }
}

private func printHosts(_ hosts: [HostStatus]) {
  let width = hosts.map(\.name.count).max() ?? 0
  func pad(_ text: String, _ length: Int) -> String { text.padding(toLength: length, withPad: " ", startingAt: 0) }
  for h in hosts {
    let state = h.problem != nil ? "invalid" : h.link?.rawValue ?? "-"
    let detail = h.problem ?? h.destination ?? "perSession layout"
    // The widths of the longest kind, hogli, and the longest state, disconnected.
    print("\(pad(h.name, width))  \(pad(h.kind ?? "-", 5))  \(pad(state, 12))  \(detail)")
    for line in h.error?.split(whereSeparator: \.isNewline) ?? [] { print("    \(line)") }
    if let retryAt = h.retryAt { print("    Tries again in \(max(0, retryAt - nowMs()) / 1000) s") }
  }
}
