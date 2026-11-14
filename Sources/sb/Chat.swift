import Foundation
import SwitchboardCore

func chat(_ a: Args) {
  guard let group = a.positional.first else { die("chat needs a group") }
  if a.switches.contains("--log") { return printChatLog(a, ["group": .string(group)]) }
  if a.switches.contains("--read") { return markRead(a, ["group": .string(group)]) }
  var args: [String: JSON] = ["group": .string(group)]
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
  var args = args
  if let caller = ProcessInfo.processInfo.environment["SB_SESSION_ID"] { args["caller"] = .string(caller) }
  let result = call(ChatActivity.readEvent, args)
  if a.json { return printJSON(result) }
  let s = summary(result)
  print("\(s.name): \(s.activity?.text ?? "read")".printable)
}

extension ChatActivity {
  /// The unread count and the time of the last message.
  var text: String {
    let unreadText = unread == 0 ? "no unread replies" : unread == 1 ? "1 unread reply" : "\(unread) unread replies"
    return lastMessageAt.map { "\(unreadText), last message \(ago($0)) ago" } ?? unreadText
  }
}
