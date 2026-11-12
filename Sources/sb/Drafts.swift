import Foundation
import SwitchboardCore

/// Runs `draft check <session> <n>`, which reads the GitHub comment that
/// the session's draft n replies to again and prints the draft's state.
func draftCommand(_ a: Args) {
  guard a.positional.first == "check" else { die("draft takes check. See sb help") }
  guard a.positional.count == 3, let number = Int(a.positional[2]) else {
    die("draft check needs a session and a draft number, as in: sb draft check <session> 1")
  }
  let id = a.positional[1]
  // sbd reads the comment and its thread's root, each with a 30 s limit.
  let result = call("draft-check", ["session": .string(id), "draft": .number(Double(number))], timeout: 120)
  if a.json { return printJSON(result) }
  let item = decode(result, as: TriageItem.self)
  guard let draft = item.drafts.first(where: { $0.number == number }) else { die("\(id) has no draft \(number)") }
  print((draftStateLine(draft, session: id) ?? "Copy only").printable)
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
    return "Replies to @\(target.author) \(place(of: target)). Post it: sb draft post \(session) \(draft.number)"
  }
}

/// Where the reply goes, as in "on a.swift line 3".
private func place(of target: ResolvedTarget) -> String {
  switch (target.path, target.line) {
  case (let path?, let line?): "on \(path) line \(line)"
  case (let path?, nil): "on \(path)"
  case (nil, _): target.target.kind == .review ? "on their review" : "in the PR conversation"
  }
}
