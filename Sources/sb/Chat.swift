import Foundation
import SwitchboardCore

func chat(_ a: Args) {
  guard let group = a.positional.first else { die("chat needs a group") }
  if a.switches.contains("--log") { return printChatLog(a, ["group": .string(group)]) }
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
