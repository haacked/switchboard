import Foundation
import SwitchboardCore

func account(_ a: Args) {
  let words = a.positional
  var result: JSON
  switch words.first {
  case nil, "ls", "list":
    result = call("accounts")
  case "use":
    guard words.count == 2 else { die("usage: sb account use <name|folder>") }
    result = call("account-use", ["account": .string(words[1])])
  default:
    die("usage: sb account [use <name|folder>]")
  }
  if a.json { return printJSON(result) }
  for info in decode(result, as: [AccountInfo].self) {
    let folder = (info.folder as NSString).abbreviatingWithTildeInPath
    let count = "\(info.sessions) session\(info.sessions == 1 ? "" : "s")"
    print("\(info.active ? "*" : " ") \(info.name.padding(toLength: 12, withPad: " ", startingAt: 0))  \(folder), \(count)")
  }
}
