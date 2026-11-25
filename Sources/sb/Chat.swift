import Foundation
import SwitchboardCore

/// `sb chat <group> [--new [--name N] | --session <conv>] [text]`, `sb chat <group> --ls`,
/// `sb chat <group> --end <conv> [--drop <id>]… [--new [--name N]]`, or `sb chat <group> --log | --read`. Without
/// `--new` or `--session` it opens the group's most recent chat.
func chat(_ a: Args) {
  guard let group = a.positional.first else { die("chat needs a group") }
  if a.switches.contains("--log") { return printChatLog(a, ["group": .string(group)]) }
  if a.switches.contains("--read") { return markRead(a, ["group": .string(group)]) }
  if a.switches.contains("--ls") {
    let result = call("chat-ls", ["group": .string(group)])
    return a.json ? printJSON(result) : printConversations(result)
  }
  if let ref = a.values["--end"] {
    return endConversation(a, ref, scope: ["group": .string(group)], command: "sb chat \(group) --end")
  }
  var args: [String: JSON] = ["group": .string(group)]
  if a.switches.contains("--new") {
    args["new"] = true
    if let name = a.values["--name"] { args["name"] = .string(name) }
  }
  if let ref = a.values["--session"] { args["session"] = .string(ref) }
  let words = a.positional.dropFirst().joined(separator: " ")
  if let text = a.values["--send"] ?? (words.isEmpty ? nil : words) {
    if text.isEmpty { die("--send needs text") }
    args["text"] = .string(text)
  }
  printOpenOrSend(a, call("chat", args, timeout: 300))
}

/// Prints the messages that `chat-log` returns for `args`.
func printChatLog(_ a: Args, _ args: [String: JSON]) {
  let result = call("chat-log", args)
  if a.json { return printJSON(result) }
  for message in decode(result, as: [ChatMessage].self) {
    print("\(message.role.label):\n\(message.text)\n".printable)
  }
}

/// Prints how a message was delivered, or the opened session without one.
func printOpenOrSend(_ a: Args, _ result: JSON) {
  if a.json { return printJSON(result) }
  if let delivery = result["delivery"]?.string { return print(delivery) }
  printSession(summary(result))
}

/// Runs `chat-read`, which marks every reply of the chat that `args` names
/// read. sbd refuses it inside a session, because only the user reads a chat.
func markRead(_ a: Args, _ args: [String: JSON]) {
  let result = call(ChatActivity.readEvent, args.merging(callerArg) { $1 })
  if a.json { return printJSON(result) }
  let s = summary(result)
  print("\(s.name): \(s.activity?.text ?? "read")".printable)
}

extension ChatActivity {
  /// The unread count and the time of the last message.
  var text: String {
    let unreadText = ChatActivity.unreadText(unread)
    return lastMessageAt.map { "\(unreadText), last message \(ago($0)) ago" } ?? unreadText
  }
}
