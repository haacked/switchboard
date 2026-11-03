import AppKit
import SwiftTerm
import SwiftUI

/// A terminal that attaches to one of sbd's tmux panes. Closing the view ends
/// only the tmux client, so the pane keeps running in sbd.
struct TerminalPane: NSViewRepresentable {
  let command: [String]

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> LocalProcessTerminalView {
    let view = ThemedTerminalView(frame: .zero)
    view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    view.optionAsMetaKey = true
    view.processDelegate = context.coordinator
    let env = ProcessInfo.processInfo.environment
    var childEnv = ["TERM=xterm-256color", "COLORTERM=truecolor", "LANG=\(env["LANG"] ?? "en_US.UTF-8")"]
    for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
      if let value = env[key] { childEnv.append("\(key)=\(value)") }
    }
    view.startProcess(executable: command[0], args: Array(command.dropFirst()), environment: childEnv)
    return view
  }

  func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}

  static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
    view.terminate()
  }

  final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
      DispatchQueue.main.async {
        source.feed(text: "\r\n[detached from Switchboard's terminal]\r\n")
      }
    }
  }
}
