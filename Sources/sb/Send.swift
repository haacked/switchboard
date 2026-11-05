import Foundation
import SwitchboardCore

/// `sb send <session> [--image <path>]… [text]`. The `--image` pairs right
/// after the session are flags, and every word after them is text.
func sendCommand(_ a: Args) {
  var words = a.positional.dropFirst()
  var paths: [String] = []
  while words.first == "--image" {
    words.removeFirst()
    guard let path = words.popFirst() else { die("--image needs a path") }
    paths.append(path)
  }
  let text = words.joined(separator: " ")
  if text.isEmpty && paths.isEmpty { die("send needs text") }
  var args: [String: JSON] = ["session": .string(a.session("send")), "text": .string(text)]
  if !paths.isEmpty {
    args["images"] = .array(
      paths.map { path in
        let file = URL(fileURLWithPath: path.expandingTilde)
        do {
          return Attachments.json(name: file.lastPathComponent, data: try Attachments.read(path: file.path))
        } catch {
          die("\(error)")
        }
      })
  }
  let result = call("send", args)
  if a.json { printJSON(result) } else { print(result["delivery"]?.string ?? "sent") }
}
