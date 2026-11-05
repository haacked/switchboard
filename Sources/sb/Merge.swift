import Foundation
import SwitchboardCore

/// Runs `merge`, which merges a Ready to merge session's PR or adds it to its
/// repository's merge queue. With `--dismiss` it takes the session out of
/// Ready to merge. A PR reference, such as `#N`, `owner/name#N`, or a PR URL,
/// names the session by its open PR.
func merge(_ a: Args) {
  // A session that read injected instructions could otherwise merge its own
  // or another session's PR. The app's Merge button is the user's click.
  if ProcessInfo.processInfo.environment["CLAUDECODE"] != nil {
    die("merge needs your click, so it doesn't run inside Claude Code. Use the merge card in the app.")
  }
  let target = a.session("merge")
  var args: [String: JSON] = [:]
  if let pr = Wait.PullRequest(parsing: target) {
    args["pr"] = .number(Double(pr.number))
    if let repository = pr.repository { args["repository"] = .string(repository) }
  } else {
    args["session"] = .string(target)
  }
  let dismiss = a.switches.contains("--dismiss")
  if dismiss { args["dismiss"] = true }
  // sbd waits up to 120 s for `gh pr merge`.
  let result = call("merge", args, timeout: 180)
  if a.json { return printJSON(result) }
  let s = summary(result)
  let pr = s.pr.map { "#\($0.number)" } ?? "the PR"
  let verb = dismiss ? "dismissed" : s.pr?.mergeMethod?.enqueues == true ? "enqueued" : "merged"
  print("\(verb) \(pr) of \(s.name)")
}
