import Foundation
import SwitchboardCore

/// A session's link as `sb get` prints it: `  link: <id>  <title>  <url>  (<caption>)`, then a Slack thread's status.
func linkLine(_ l: ExternalLink) -> String {
  let status = l.status.map { "  " + $0.line(now: nowMs()) } ?? ""
  return "  link: \(l.id)  \(l.title)  \(l.url)  (\(l.caption()))\(status)".printable
}

/// `sb link add <session> <url> [--title T]` and `sb link rm <session> <link-id>`. Inside Claude, sbd takes the
/// request as Claude's and allows it only on the session in SB_SESSION_ID.
func linkCommand(_ a: Args) {
  let words = Array(a.positional.dropFirst())
  var args = callerArg
  args["by"] = .string(author.rawValue)
  let result: JSON
  switch a.positional.first {
  case "add":
    guard words.count == 2 else { die("link add needs a session and a URL") }
    args["session"] = .string(words[0])
    args["url"] = .string(words[1])
    if let title = a.values["--title"] { args["title"] = .string(title) }
    result = call("link-add", args)
  case "rm":
    guard words.count == 2 else { die("link rm needs a session and a link id") }
    args["session"] = .string(words[0])
    args["link"] = .string(words[1])
    result = call("link-rm", args)
  default:
    die("usage: sb link add <session> <url> [--title T] | rm <session> <link-id>")
  }
  if a.json { return printJSON(result) }
  let links = summary(result).links ?? []
  if links.isEmpty { print("No links.") }
  for l in links.reversed() { print(linkLine(l)) }
}
