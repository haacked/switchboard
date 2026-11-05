import Foundation
import SwitchboardCore

/// Runs `merge`, which merges a Ready to merge session's PR, or with
/// `--dismiss` acknowledges the session's Ready to merge item. A PR reference, such
/// as `#N`, `owner/name#N`, or a PR URL, names the session by its open PR.
func merge(_ a: Args) {
  // A session that read injected instructions could otherwise merge its own
  // or another session's PR. The app's Merge button is the user's click.
  if ProcessInfo.processInfo.environment["CLAUDECODE"] != nil {
    die("merge needs your click, so it doesn't run inside Claude Code. Use the merge card in the app.")
  }
  var args = sessionOrPR(a.session("merge"))
  let dismiss = a.switches.contains("--dismiss")
  if dismiss { args["dismiss"] = true }
  // sbd waits up to 120 s for `gh pr merge`.
  let result = call("merge", args, timeout: 180)
  if a.json { return printJSON(result) }
  let s = summary(result)
  let pr = s.pr.map { "#\($0.number)" } ?? "the PR"
  print(dismiss ? "acknowledged \(pr) of \(s.name)" : "merged \(pr) of \(s.name)")
}

/// The request arguments that name a session, or the session whose open PR
/// is the PR reference, such as `#N`, `owner/name#N`, or a PR URL.
func sessionOrPR(_ target: String) -> [String: JSON] {
  guard let pr = Wait.PullRequest(parsing: target) else { return ["session": .string(target)] }
  var args: [String: JSON] = ["pr": .number(Double(pr.number))]
  if let repository = pr.repository { args["repository"] = .string(repository) }
  return args
}
