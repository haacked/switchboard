import Foundation
import SwitchboardCore

/// Runs `review`, which lists the suggested reviewers of a session that shows
/// the review card, requests a review from the reviewers it names, or with
/// `--dismiss` hides the card. A PR reference, such as `#N`, `owner/name#N`,
/// or a PR URL, names the session by its open PR.
func review(_ a: Args) {
  // A session that read injected instructions could otherwise ask people
  // to review its PR. The app's Request review button is the user's click.
  if ProcessInfo.processInfo.environment["CLAUDECODE"] != nil {
    die("review needs your click, so it doesn't run inside Claude Code. Use the review card in the app.")
  }
  let target = a.session("review")
  var args = sessionOrPR(target)
  let reviewers = Array(a.positional.dropFirst())
  let dismiss = a.switches.contains("--dismiss")
  if dismiss { args["dismiss"] = true }
  if !reviewers.isEmpty { args["reviewers"] = .array(reviewers.map(JSON.string)) }
  // sbd waits up to 60 s for gh.
  let result = call("review", args, timeout: 120)
  if a.json { return printJSON(result) }
  if let suggestions = result["suggestions"]?.array {
    let rows = suggestions.compactMap { s in s["login"]?.string.map { ($0, s["reason"]?.string ?? "") } }
    let width = rows.map(\.0.count).max() ?? 0
    for (login, reason) in rows { print("\(login.padding(toLength: width, withPad: " ", startingAt: 0))  \(reason)") }
    print("\nRequest with: sb review \(target) <reviewer>...")
    return
  }
  let s = summary(result)
  let pr = s.pr.map { "#\($0.number)" } ?? "the PR"
  print(dismiss ? "dismissed the review card of \(pr) of \(s.name)" : "requested a review of \(pr) from \(reviewers.joined(separator: ", "))")
}
