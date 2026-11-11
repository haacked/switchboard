import Foundation
import SwitchboardCore

/// `sb repo [ls]` lists the repositories that the New Session sheet offers. `sb repo add <path>` adds the
/// repository that holds the folder and prints its entry.
func repo(_ a: Args) {
  let verb = a.positional.first ?? "ls"
  let result: JSON
  switch verb {
  case "ls":
    result = call("repos")
  case "add":
    // An empty path would become sb's own folder below.
    guard a.positional.count > 1, !a.positional[1].isEmpty else { die("repo add needs a path") }
    // sbd runs in another folder, so a relative path becomes absolute here.
    let path = URL(fileURLWithPath: a.positional[1].expandingTilde).standardizedFileURL.path
    result = call("repo-add", ["path": .string(path)])
  default:
    die("unknown repo command \(verb). Use ls or add")
  }
  if a.json {
    printJSON(result)
    return
  }
  let repos = verb == "add" ? [decode(result, as: KnownRepo.self)] : decode(result, as: [KnownRepo].self)
  let width = repos.map(\.name.count).max() ?? 0
  for r in repos { print("\(r.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(r.path)") }
}
