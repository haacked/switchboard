import Foundation
import SwitchboardCore

/// Lists what `sb rm --done` removes and skips, asks the user to confirm,
/// then removes. Without a terminal or inside Claude, it needs --yes. With
/// --json and without --yes, it prints the plan and removes nothing.
func removeDone(_ a: Args) {
  if a.switches.contains("--delete-branch") {
    die("rm --done deletes a branch only when its PR merged it. Pass --worktree for that.")
  }
  if a.switches.contains("--delete-remote-branch") && !a.switches.contains("--worktree") {
    die("--delete-remote-branch needs --worktree")
  }
  var args: [String: JSON] = [
    "worktree": .bool(a.switches.contains("--worktree")),
    "remote_branch": .bool(a.switches.contains("--delete-remote-branch")),
  ]
  let preview = call("rm-done", args, timeout: 300)
  let yes = a.switches.contains("--yes")
  if a.json && !yes { return printJSON(preview) }
  let plan = decode(preview, as: DoneRemovalPlan.self)
  let text = describe(plan)
  if plan.remove.isEmpty {
    if a.json { return printResult(DoneRemovalResult(removed: [], skipped: plan.skip, partial: [])) }
    print(text)
    return
  }
  if !yes {
    let count = plan.remove.count == 1 ? "this session" : "these \(plan.remove.count) sessions"
    guard author != .claude else { die("pass --yes to remove \(count):\n\(text)") }
    confirm(verb: "remove", count, text, refused: "removed nothing")
  }
  args["confirmed"] = true
  args["targets"] = .array(plan.remove.map { .string($0.id) })
  var done = decode(call("rm-done", args, timeout: 600), as: DoneRemovalResult.self)
  done.skipped = plan.skip + done.skipped
  if a.json { return printResult(done) }
  print("removed \(done.removed.count), skipped \(done.skipped.count)")
  for s in done.partial { print("  \(s.id)  \(s.name): \(s.reason)".printable) }
  for s in done.skipped { print("  skipped \(s.id)  \(s.name): \(s.reason)".printable) }
}

private func printResult(_ result: DoneRemovalResult) {
  do { printJSON(try JSON(encoding: result)) } catch { die("\(error)") }
}

private func describe(_ plan: DoneRemovalPlan) -> String {
  var lines: [String] = []
  if plan.remove.isEmpty { lines.append("No Done session to remove.") }
  for item in plan.remove {
    var parts = ["session"]
    if let worktree = item.worktree { parts.append("worktree \(worktree)") }
    if let branch = item.branch { parts.append("branch \(branch)") }
    if item.remoteBranch { parts.append("remote branch") }
    let pr = item.pr.map { " #\($0)" } ?? ""
    lines.append("  \(item.id)  \(item.name)\(pr): \(parts.joined(separator: ", "))".printable)
  }
  if !plan.skip.isEmpty { lines.append("Skipped:") }
  for s in plan.skip { lines.append("  \(s.id)  \(s.name): \(s.reason)".printable) }
  return lines.joined(separator: "\n")
}
