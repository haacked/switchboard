import Foundation
import SwitchboardCore

/// `sb issues`: the open issues from the configured sources, which sbd caches.
func issues(_ a: Args) {
  let words = Array(a.positional.dropFirst())
  switch a.positional.first {
  case nil:
    var list = decode(call("issues"), as: IssueList.self)
    if a.switches.contains("--mine") { list.issues.removeAll { $0.bucket != .mine } }
    if a.json { printJSON((try? JSON(encoding: list)) ?? .null) } else { printIssues(list) }
  case "start":
    guard let ref = words.first else { die("usage: sb issues start <owner/name#N> [--preset P] [--group G]") }
    var args: [String: JSON] = ["issue": .string(ref)]
    if let preset = a.values["--preset"] { args["preset"] = .string(preset) }
    if let group = a.values["--group"] { args["group"] = .string(group) }
    if let path = a.values["--path"] { args["path"] = .string(URL(fileURLWithPath: path.expandingTilde).path) }
    let result = call("issues-start", args, timeout: 300)
    if a.json { printJSON(result) } else { printSession(summary(result)) }
  case "source", "sources":
    issueSource(a, words)
  case "team":
    var args: [String: JSON] = [:]
    if let labels = a.allValues["--label"] { args["labels"] = .array(labels.map(JSON.string)) }
    if let people = a.allValues["--person"] { args["people"] = .array(people.map(JSON.string)) }
    let team = decode(call(args.isEmpty ? "issues" : "issues-settings", args), as: IssueList.self).team
    if a.json {
      printJSON((try? JSON(encoding: team)) ?? .null)
    } else {
      print("labels: \(team.labels.isEmpty ? "none" : team.labels.joined(separator: ", "))")
      print("people: \(team.people.isEmpty ? "none" : team.people.joined(separator: ", "))")
    }
  default:
    die("usage: sb issues [--mine] | start | source add|rm|ls | team")
  }
}

private func issueSource(_ a: Args, _ words: [String]) {
  var args: [String: JSON] = [:]
  if let label = a.values["--label"] { args["label"] = .string(label) }
  if let person = a.values["--person"] { args["person"] = .string(person) }
  let result: JSON
  switch words.first {
  case "add", "rm":
    guard words.count == 2 else { die("usage: sb issues source \(words[0]) <org|owner/name> [--label L] [--person P]") }
    args["source"] = .string(words[1])
    result = call("issues-source-\(words[0])", args)
  case "ls", "list", nil:
    result = (try? JSON(encoding: decode(call("issues"), as: IssueList.self).sources)) ?? .array([])
  default:
    die("usage: sb issues source add|rm|ls")
  }
  if a.json {
    printJSON(result)
  } else {
    let sources = decode(result, as: [IssueSource].self)
    if sources.isEmpty { print(noSources) }
    for source in sources { print(source.key) }
  }
}

private func printIssues(_ list: IssueList) {
  if list.sources.isEmpty {
    print(noSources)
    return
  }
  if let error = list.error { warn(error) }
  for bucket in IssueBucket.allCases {
    let rows = list.issues.filter { $0.bucket == bucket }
    guard !rows.isEmpty else { continue }
    print("\(bucket.title) (\(rows.count))")
    for row in IssueSort.updated.sorted(rows.map(\.issue)) {
      let assignees = row.assignees.isEmpty ? "" : "  @\(row.assignees.joined(separator: " @"))"
      print("  \(row.repo)#\(row.number)  \(row.title)\(assignees)")
    }
  }
  if list.issues.isEmpty { print("No open issues from \(list.sources.count) sources.") }
}

private let noSources = "No sources. Add one with: sb issues source add <org|owner/name> [--label L]"
