import Foundation
import SwitchboardCore

func account(_ a: Args) {
  let words = a.positional
  switch words.first {
  case nil, "ls", "list":
    printAccounts(call("accounts"), json: a.json)
  case "use":
    guard words.count == 2 else { die("usage: sb account use <name|folder> [--move | --new-only]") }
    let ref = words[1]
    let move = moveChoice(a, ref)
    let accounts = call("account-use", ["account": .string(ref)])
    guard move else { return printAccounts(accounts, json: a.json) }
    let moved = call("account-move", ["account": .string(ref)])
    if a.json { return printJSON(["accounts": accounts, "move": moved]) }
    printAccounts(accounts, json: false)
    printMove(decode(moved, as: AccountMove.self))
  case "move":
    guard words.count == 2 else { die("usage: sb account move <name|folder> [--dry-run]") }
    let result = call(
      "account-move", ["account": .string(words[1]), "dryRun": .bool(a.switches.contains("--dry-run"))])
    if a.json { return printJSON(result) }
    printMove(decode(result, as: AccountMove.self), dryRun: a.switches.contains("--dry-run"))
  default:
    die("usage: sb account [use <name|folder> [--move | --new-only] | move <name|folder> [--dry-run]]")
  }
}

/// Whether `use` also moves the existing sessions. `--move` and `--new-only`
/// answer it. Without either, a terminal asks when a session could move, and a
/// script gets the new sessions only.
func moveChoice(_ a: Args, _ ref: String) -> Bool {
  if a.switches.contains("--move") { return true }
  if a.switches.contains("--new-only") || a.json || isatty(0) == 0 { return false }
  let plan = decode(call("account-move", ["account": .string(ref), "dryRun": .bool(true)]), as: AccountMove.self)
  guard !plan.moved.isEmpty else { return false }
  printMove(plan, dryRun: true)
  print("\n\(AccountMove.consequences)\n")
  print("Move \(plan.moved.count) session\(plan.moved.count == 1 ? "" : "s") too? [y/N] ", terminator: "")
  return ["y", "yes"].contains(readLine()?.lowercased() ?? "")
}

func printAccounts(_ result: JSON, json: Bool) {
  if json { return printJSON(result) }
  for info in decode(result, as: [AccountInfo].self) {
    let folder = (info.folder as NSString).abbreviatingWithTildeInPath
    let count = "\(info.sessions) session\(info.sessions == 1 ? "" : "s")"
    print(
      "\(info.active ? "*" : " ") \(info.name.padding(toLength: 12, withPad: " ", startingAt: 0))  \(folder), \(count)")
  }
}

func printMove(_ move: AccountMove, dryRun: Bool = false) {
  let name = ClaudeAccount.name(move.account)
  let n = move.moved.count
  print(
    "\(dryRun ? "\(n) session\(n == 1 ? "" : "s") would move" : "Moved \(n) session\(n == 1 ? "" : "s")") to \(name)")
  for b in move.blocked { print("  stays: \(b.session)  \(b.name): \(b.reason)") }
}
