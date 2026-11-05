import AppKit
import SwiftTerm

/// A scripted check of the shell pane, run by `bin/test-gui`. SB_SHELL_TEST=<folder> makes the app run each
/// command that a script writes to <folder>/cmd, one at a time. The app deletes the file and appends
/// "shelltest: <command> -> <result>" to standard error when the command is done. The commands are:
/// `click close` clicks the × on the Shell pane's label with mouse events at the button's place in the
/// window. `click open` clicks Open Shell on the Claude pane's label the same way. SwiftUI builds no
/// accessibility elements without an assistive app, so the test can't press a button by its label.
/// `menu <menu> <item>` runs a menu item. `chat-terminal` shows a chat's terminals, as its Terminal toggle
/// does. `select <session>` selects a session. `type <text>` types the text and Return into the shell pane.
/// `ctrl-d` types Ctrl-D there. `panes` reports how many terminals the window shows. `cmd-w` sends ⌘W to
/// the menu bar and reports the menu item that owns ⌘W. `snapshot <path>` draws the window as SB_SNAPSHOT
/// does.
@MainActor
enum ShellSelfTest {
  static func start(_ model: BoardModel) {
    guard let folder = ProcessInfo.processInfo.environment["SB_SHELL_TEST"] else { return }
    let path = "\(folder)/cmd"
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
      MainActor.assumeIsolated {
        guard let command = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: path)
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        log("\(line) -> \(run(line, model))")
      }
    }
  }

  private static func run(_ line: String, _ model: BoardModel) -> String {
    let words = line.split(separator: " ", maxSplits: 1).map(String.init)
    let rest = words.count > 1 ? words[1] : ""
    switch words.first {
    case "click":
      let (target, inset): (TerminalView?, CGFloat) = rest == "close" ? (shellPane(), 14) : (panes().first, 30)
      guard let window, let pane = target else { return "no pane" }
      // The pane's label is a bar about 18 pt tall above the terminal, with its button at the right end.
      let frame = pane.convert(pane.bounds, to: nil)
      let point = NSPoint(x: frame.maxX - inset, y: frame.maxY + 9)
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard
          let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return "no event" }
        window.sendEvent(event)
      }
      return "clicked at \(Int(point.x)),\(Int(point.y))"
    case "chat-terminal":
      model.showingTerminal = true
      return "shown"
    case "menu":
      let names = rest.split(separator: " ", maxSplits: 1).map(String.init)
      guard names.count == 2, let menu = NSApp.mainMenu?.item(withTitle: names[0])?.submenu else { return "no menu" }
      // SwiftUI sets the items' titles when the menu opens.
      menu.delegate?.menuNeedsUpdate?(menu)
      menu.update()
      let index = menu.indexOfItem(withTitle: names[1])
      guard index >= 0 else { return "not found in \(menu.items.map(\.title))" }
      guard menu.items[index].isEnabled else { return "disabled" }
      menu.performActionForItem(at: index)
      return "ran"
    case "select":
      model.selection = rest
      return "selected"
    case "type":
      guard let pane = shellPane() else { return "no shell pane" }
      for char in rest.map(String.init) {
        TerminalSelfTest.key(pane, char, code: TerminalSelfTest.code(for: char))
      }
      TerminalSelfTest.key(pane, "\r", code: 36)
      return "typed"
    case "ctrl-d":
      guard let pane = shellPane() else { return "no shell pane" }
      TerminalSelfTest.key(pane, "\u{04}", "d", code: TerminalSelfTest.code(for: "d"), mods: .control)
      return "typed"
    case "panes":
      return "\(panes().count)"
    case "cmd-w":
      guard let window,
        let event = NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w",
          isARepeat: false, keyCode: TerminalSelfTest.code(for: "w"))
      else { return "no window" }
      let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) == true
      let owner = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first {
        $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == .command
      }
      return "handled \(handled) by \(owner?.title ?? "no item")"
    case "snapshot":
      Snapshot.write(to: rest)
      return "wrote"
    default:
      return "unknown command"
    }
  }

  private static var window: NSWindow? { TerminalSelfTest.window }

  private static func panes() -> [TerminalView] { TerminalSelfTest.panes() }

  /// The right terminal, when the window shows two.
  private static func shellPane() -> TerminalView? {
    let panes = panes()
    return panes.count == 2 ? panes.last : nil
  }

  private static func log(_ text: String) { FileHandle.standardError.write(Data("shelltest: \(text)\n".utf8)) }
}
