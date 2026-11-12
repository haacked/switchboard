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
  if author == .claude, let from = ProcessInfo.processInfo.environment["SB_SESSION_ID"] { args["from"] = .string(from) }
  if !paths.isEmpty {
    var total = 0
    do { try Attachments.checkMessage(count: paths.count, total: 0) } catch { die("\(error)") }
    args["images"] = .array(
      paths.map { path in
        let file = URL(fileURLWithPath: path.expandingTilde)
        do {
          let data = try Attachments.read(path: file.path)
          total += data.count
          try Attachments.checkMessage(count: paths.count, total: total)
          return Attachments.json(name: file.lastPathComponent, data: data)
        } catch {
          die("\(error)")
        }
      })
  }
  let result = call("send", args)
  if a.json { printJSON(result) } else { print(result["delivery"]?.string ?? "sent") }
}
