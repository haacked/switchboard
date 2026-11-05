import Foundation
import SwitchboardCore

func docket(_ a: Args) {
  guard let pr = a.positional.first, a.positional.count == 1 else { die("docket needs one pull request") }
  var args: [String: JSON] = ["pr": .string(pr)]
  if let existing = a.values["--existing"] { args["existing"] = .string(existing) }
  if let name = a.values["--name"] { args["name"] = .string(name) }
  if let group = a.values["--group"] { args["group"] = .string(group) }
  // A review started inside a session records that session as its parent.
  if let parent = a.values["--parent"] ?? ProcessInfo.processInfo.environment["SB_SESSION_ID"] {
    args["parent"] = .string(parent)
  }
  let result = call("docket-start", args, timeout: 300)
  if a.json { printJSON(result) } else { printSession(summary(result)) }
}

func printDocket(_ d: DocketSummary) {
  let state = d.closed ? "closed" : d.review?.state ?? "starting"
  print("  docket:  \(state)  \(d.pullRequest)  \(d.url)".printable)
  if let title = d.review?.title { print("  title:   \(title)".printable) }
  if let detail = d.review?.progress?.detail { print("  doing:   \(detail)".printable) }
  if let notes = d.review?.notesPath { print("  notes:   \(notes)".printable) }
  if let error = d.review?.error, !error.isEmpty { print("  error:   \(error)".printable) }
  if let problem = d.problem { print("  problem: \(problem)".printable) }
}
