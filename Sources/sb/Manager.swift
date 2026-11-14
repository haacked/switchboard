import Foundation
import SwitchboardCore

/// `sb manager [ls | new [--name N] [text] | mcp <conv> … | pin <conv> | unpin <conv> | <conv> [text] [--log | --read]]`.
/// Without a conversation it opens the most recent one.
func manager(_ a: Args) {
  var words = a.positional[...]
  switch words.first {
  case "ls":
    let result = call("manager-ls")
    if a.json { return printJSON(result) }
    for s in decode(result, as: [SessionSummary].self) {
      var marks: [String] = []
      if let unread = s.activity?.unread, unread > 0 { marks.append("\(unread) unread") }
      if s.pinned == true { marks.append("pinned") }
      if s.activity?.archived == true { marks.append("archived") }
      let extra = marks.map { "  \($0)" }.joined()
      print("\(s.id)  \(s.name)  \(s.state.title)  \(Manager.serversText(s.mcp))\(extra)".printable)
    }
    return
  case "mcp":
    words.removeFirst()
    return managerMCP(a, Array(words))
  case "pin", "unpin":
    let verb = words.removeFirst()
    guard let ref = words.first else { die("manager \(verb) needs a conversation") }
    let result = call("manager-pin", ["session": .string(ref), "pinned": .bool(verb == "pin")])
    if a.json { return printJSON(result) }
    let s = summary(result)
    return print("\(s.name): \(s.pinned == true ? "pinned" : "not pinned")".printable)
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
  let conversation = args.merging(["manager": true]) { $1 }
  if a.switches.contains("--log") { return printChatLog(a, conversation) }
  if a.switches.contains("--read") { return markRead(a, conversation) }
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
  let answer = decode(result, as: ManagerMCPAnswer.self)
  print("\(answer.name): \(Manager.serversText(answer.servers))".printable)
  if answer.pending { print(Manager.relaunchPendingText) }
  if !answer.available.isEmpty { print("Servers you can add: \(answer.available.joined(separator: ", "))") }
}
