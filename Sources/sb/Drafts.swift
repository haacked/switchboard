import Foundation
import SwitchboardCore

/// Runs `draft post <session> <n>`, which posts the session's draft n to
/// GitHub as the user, or `draft check <session> <n>`, which reads the
/// GitHub comment that draft n replies to again, or looks for the reply of
/// a post whose outcome sbd doesn't know, and prints the draft's state.
func draftCommand(_ a: Args) {
  let sub = a.positional.first ?? ""
  guard ["post", "check"].contains(sub) else { die("draft takes post or check. See sb help") }
  guard a.positional.count == 3, let number = Int(a.positional[2]) else {
    die("draft \(sub) needs a session and a draft number, as in: sb draft \(sub) <session> 1")
  }
  let id = a.positional[1]
  if sub == "post" { return postDraft(a, id, number) }
  // sbd reads the comment and its thread's root, each with a 30 s limit.
  let result = call("draft-check", ["session": .string(id), "draft": .number(Double(number))], timeout: 120)
  if a.json { return printJSON(result) }
  let item = decode(result, as: TriageItem.self)
  guard let draft = item.drafts.first(where: { $0.number == number }) else { die("\(id) has no draft \(number)") }
  print((draftStateLine(draft, session: id) ?? "Copy only").printable)
}

/// Posts the text of `--text`, of stdin with `--text -`, or else the draft's
/// own text. sbd also refuses a caller inside any session.
private func postDraft(_ a: Args, _ id: String, _ number: Int) {
  // A session that read injected instructions could otherwise post as the user.
  refuseInsideClaudeCode(
    "draft post needs your click, so it doesn't run inside Claude Code. Run it from a terminal outside the sessions.")
  // The item that the user read, so a draft of a newer item is not posted by mistake.
  guard let item = summary(call("get", ["session": .string(id)])).triage else { die("\(id) needs nothing from you") }
  guard let draft = item.drafts.first(where: { $0.number == number }) else { die("\(id) has no draft \(number)") }
  var text = a.values["--text"] ?? draft.text
  if text == "-" { text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
  let args: [String: JSON] = [
    "session": .string(id), "ref": .string(item.ref), "draft": .number(Double(number)), "text": .string(text),
  ]
  // sbd waits up to 60 s for the POST.
  let result = call("draft-post", args, timeout: 180)
  if a.json { return printJSON(result) }
  let posted = (try? JSONCoding.convert(result, to: TriageItem.self))?.drafts.first { $0.number == number }
  if case .posted(_, let url, _) = posted?.post { return print("Posted: \(url)".printable) }
  print("Posted\(result["url"]?.string.map { ": \($0)" } ?? "")".printable)
}

/// The line under a draft that says what its Post button may do, or nil
/// for a draft that only copies and names no target.
func draftStateLine(_ draft: InboxDraft, session: String) -> String? {
  switch draft.post {
  case .copyOnly(nil):
    return nil
  case .copyOnly(let reason?):
    return "Copy only: \(reason)"
  case .checking:
    return "Checking the comment on GitHub…"
  case .unresolved(let error):
    return "Can't read the comment on GitHub: \(error). Check again: sb draft check \(session) \(draft.number)"
  case .ready(let target):
    return "Replies to @\(target.author) \(target.place). Post it: sb draft post \(session) \(draft.number)"
  case .posting:
    return "Posting to GitHub…"
  case .posted(_, let url, _):
    return "Posted: \(url)"
  case .failed(let target, let error):
    return
      "Didn't post: \(error). It replies to @\(target.author) \(target.place). Post it again: sb draft post \(session) \(draft.number)"
  case .unknown(_, let error):
    return DraftReplies.unknownLine(error: error, session: session, number: draft.number)
  }
}
