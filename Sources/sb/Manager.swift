import Foundation
import SwitchboardCore

/// `sb manager [ls | new [--name N] [text] | mcp <conv> … | <conv> [text] [--log]]`.
/// Without a conversation it opens the most recent one.
func manager(_ a: Args) {
  var words = a.positional[...]
  switch words.first {
  case "ls":
    let result = call("manager-ls")
    if a.json { return printJSON(result) }
    for s in decode(result, as: [SessionSummary].self) {
      print("\(s.id)  \(s.name)  \(s.state.title)  \(Manager.serversText(s.mcp))".printable)
    }
    return
  case "mcp":
    words.removeFirst()
    return managerMCP(a, Array(words))
  case "new":
    words.removeFirst()
    var args: [String: JSON] = ["new": true]
    if let name = a.values["--name"] { args["name"] = .string(name) }
    let text = words.joined(separator: " ")
    if !text.isEmpty { args["text"] = .string(text) }
    return printOpenOrSend(a, call("manager", args, timeout: 300))
  default:
    break
  }
  var args: [String: JSON] = [:]
  if let ref = words.popFirst() { args["session"] = .string(ref) }
  if a.switches.contains("--log") { return printChatLog(a, args.merging(["manager": true]) { $1 }) }
  let text = words.joined(separator: " ")
  if !text.isEmpty { args["text"] = .string(text) }
  printOpenOrSend(a, call("manager", args, timeout: 300))
}

/// `sb manager mcp <conv> [add <server>… | rm <server>… | --all | --none]`.
private func managerMCP(_ a: Args, _ words: [String]) {
  guard let ref = words.first else { die("manager mcp needs a conversation") }
  var args: [String: JSON] = ["session": .string(ref)]
  let rest = words.dropFirst()
  if let verb = rest.first {
    guard verb == "add" || verb == "rm" else { die("manager mcp takes add or rm, not \(verb)") }
    let names = rest.dropFirst()
    if names.isEmpty { die("\(verb) needs a server name") }
    args[verb] = .array(names.map(JSON.string))
  }
  if a.switches.contains("--all") { args["all"] = true }
  if a.switches.contains("--none") { args["none"] = true }
  let result = call("manager-mcp", args)
  if a.json { return printJSON(result) }
  let servers = result["servers"]?.array.map { $0.compactMap(\.string) }
  print("\(result["name"]?.string ?? ref): \(Manager.serversText(servers))".printable)
  if result["pending"]?.bool == true { print("Claude restarts with them when its turn ends.") }
  let available = result["available"]?.array?.compactMap(\.string) ?? []
  if !available.isEmpty { print("Servers you can add: \(available.joined(separator: ", "))") }
}
