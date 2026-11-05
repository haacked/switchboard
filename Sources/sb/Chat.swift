import Foundation
import SwitchboardCore

func chat(_ a: Args) {
  guard let group = a.positional.first else { die("chat needs a group") }
  if a.switches.contains("--log") {
    let result = call("chat-log", ["group": .string(group)])
    if a.json { return printJSON(result) }
    for message in decode(result, as: [ChatMessage].self) {
      print("\(message.role.label):\n\(message.text)\n".printable)
    }
    return
  }
  var args: [String: JSON] = ["group": .string(group)]
  let words = a.positional.dropFirst().joined(separator: " ")
  if let text = a.values["--send"] ?? (words.isEmpty ? nil : words) {
    if text.isEmpty { die("--send needs text") }
    args["text"] = .string(text)
  }
  let result = call("chat", args, timeout: 300)
  if a.json { return printJSON(result) }
  if let delivery = result["delivery"]?.string { return print(delivery) }
  printSession(summary(result))
}
