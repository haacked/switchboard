import AppKit
import SwiftTerm
import SwiftUI

/// A terminal that attaches to one of sbd's tmux panes. Closing the view ends
/// only the tmux client, so the pane keeps running in sbd.
struct TerminalPane: NSViewRepresentable {
  let command: [String]

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> PaddedTerminalView {
    let padded = PaddedTerminalView(frame: .zero)
    let view = padded.terminal
    view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    view.optionAsMetaKey = true
    view.processDelegate = context.coordinator
    let env = ProcessInfo.processInfo.environment
    var childEnv = ["TERM=xterm-256color", "COLORTERM=truecolor", "LANG=\(env["LANG"] ?? "en_US.UTF-8")"]
    for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
      if let value = env[key] { childEnv.append("\(key)=\(value)") }
    }
    view.startProcess(executable: command[0], args: Array(command.dropFirst()), environment: childEnv)
    return padded
  }

  func updateNSView(_ view: PaddedTerminalView, context: Context) {}

  static func dismantleNSView(_ view: PaddedTerminalView, coordinator: Coordinator) {
    view.terminal.terminate()
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

/// Holds a terminal view inset from its left and right edges, and fills the inset with the terminal's
/// background color. SwiftTerm computes columns and rows from its own frame, so the terminal sizes itself
/// to the inset width.
final class PaddedTerminalView: NSView {
  static let horizontalPadding: CGFloat = 10

  let terminal = ThemedTerminalView(frame: .zero)
  // SwiftTerm builds its mouse tracking area and its scroller hit test from its frame as if the frame were in
  // its own coordinates. The terminal therefore sits at the origin of this holder, and the holder is inset.
  private let holder = NSView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    wantsLayer = true
    holder.addSubview(terminal)
    addSubview(holder)
    placeTerminal()
    applyBackground()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func resizeSubviews(withOldSize oldSize: NSSize) {
    placeTerminal()
  }

  private func placeTerminal() {
    let pad = Self.horizontalPadding
    holder.frame = NSRect(x: pad, y: 0, width: max(0, bounds.width - 2 * pad), height: bounds.height)
    terminal.frame = holder.bounds
  }

  // A click, drag, or scroll in the padding goes to the terminal, which clamps it to the nearest column.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    return hit === self || hit === holder ? terminal : hit
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyBackground()
  }

  // AppKit does not guarantee that the terminal sees an appearance change before this view does, so this
  // view computes the color from the theme instead of reading it from the terminal.
  private func applyBackground() {
    layer?.backgroundColor = TerminalTheme(appearance: effectiveAppearance).background.cgColor
  }
}
