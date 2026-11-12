import AppKit
import SwiftTerm
import SwiftUI

/// A scripted check of the shell pane, run by `bin/test-gui`. SB_SHELL_TEST=<folder> makes the app run each
/// command that a script writes to <folder>/cmd, one at a time. When the command is done, the app appends
/// "shelltest: <command> -> <result>" to standard error and then deletes the file. The commands are:
/// `click close` clicks the × on the Shell pane's label with mouse events at the button's place in the
/// window. `click open` clicks Open Shell on the Claude pane's label the same way. SwiftUI builds no
/// accessibility elements without an assistive app, so the test can't press a button by its label.
/// `menu <menu> <item>` runs a menu item. `show-terminal` shows the terminals of a chat or an Inbox item,
/// as their Terminal toggle does. `select <session>` selects a session. `type <text>` types the text and
/// Return into the shell pane. `ctrl-d` types Ctrl-D there. `panes` reports how many terminals the window
/// shows. `cmd-w` sends ⌘W to the menu bar and reports the menu item that owns ⌘W. `nav-keys` sends each of
/// `NavShortcuts` to the menu bar as a US keyboard types it, and reports the title of the menu item that ran.
/// `mouse <3|4>` posts a press of mouse button 4 or 5 (button numbers 3 and 4) over the window to the app's
/// event queue, so it passes through the app's event monitors as a real press does. `where` reports the place
/// that the window shows. `snapshot <path>` draws the window as SB_SNAPSHOT does.
@MainActor
enum ShellSelfTest {
  static func start(_ model: BoardModel) {
    guard let folder = ProcessInfo.processInfo.environment["SB_SHELL_TEST"] else { return }
    let path = "\(folder)/cmd"
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
      MainActor.assumeIsolated {
        guard let command = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        log("\(line) -> \(run(line, model))")
        // The script reads the result once the file is gone, so the file goes only after the log line.
        try? FileManager.default.removeItem(atPath: path)
      }
    }
  }

  private static func run(_ line: String, _ model: BoardModel) -> String {
    let words = line.split(separator: " ", maxSplits: 1).map(String.init)
    let rest = words.count > 1 ? words[1] : ""
    switch words.first {
    case "click":
      let (target, offset): (TerminalView?, CGFloat) = rest == "close" ? (shellPane(), 6) : (panes().first, 25)
      guard let window, let pane = target else { return "no pane" }
      guard let point = labelPoint(of: pane, offset: offset) else { return "no label" }
      guard TerminalSelfTest.click(at: point, in: window) else { return "no event" }
      return "clicked at \(Int(point.x)),\(Int(point.y))"
    case "show-terminal":
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
    case "nav-keys":
      guard let window else { return "no window" }
      return NavShortcuts.all.map { menuItem(running: $0, in: window) }.joined(separator: "; ")
    case "mouse":
      guard let window else { return "no window" }
      guard let button = Int(rest), let event = otherMouseDown(button, in: window) else { return "no event" }
      NSApp.postEvent(event, atStart: false)
      return "posted"
    case "where":
      return "\(model.location.place)"
    case "snapshot":
      Snapshot.write(to: rest)
      return "wrote"
    default:
      return "unknown command"
    }
  }

  /// Reports the menu item that `shortcut` runs. When none runs, it reports the item that owns the key and
  /// whether that item is enabled. The event has ⇧ when the character is a shifted one, such as "}", because
  /// a keyboard sends ⇧⌘] that way.
  private static func menuItem(running shortcut: KeyboardShortcut, in window: NSWindow) -> String {
    let char = String(shortcut.key.character)
    let (code, shift) = TerminalSelfTest.keystroke(for: char)
    let flags: NSEvent.ModifierFlags = shift ? [.command, .shift] : .command
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: char, charactersIgnoringModifiers: char,
        isARepeat: false, keyCode: code)
    else { return "\(char) no event" }
    var ran: String?
    let observer = NotificationCenter.default.addObserver(
      forName: NSMenu.didSendActionNotification, object: nil, queue: nil
    ) {
      ran = ($0.userInfo?["MenuItem"] as? NSMenuItem)?.title
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
    if let ran { return "\(char) ran \(ran)" }
    let owner = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.keyEquivalent == char }
    return "\(char) ran none" + (owner.map { " (\($0.title) is \($0.isEnabled ? "enabled" : "disabled"))" } ?? "")
  }

  /// A press of the mouse button with number `button` at the window's center, or with no window when `window`
  /// is nil. AppKit's mouse event API sets no button number, so the number goes into the event's Core Graphics copy.
  static func otherMouseDown(_ button: Int, in window: NSWindow? = nil) -> NSEvent? {
    let center = window.map { NSPoint(x: $0.frame.width / 2, y: $0.frame.height / 2) } ?? .zero
    guard
      let event = NSEvent.mouseEvent(
        with: .otherMouseDown, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
      let cg = event.cgEvent
    else { return nil }
    cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
    return NSEvent(cgEvent: cg)
  }

  /// The point `offset` pt into the button on the pane's label. The label is a bar about 18 pt tall above the
  /// pane. Its button follows the label's text. The label starts at the padded view's edge, which is left of
  /// the inset terminal. A terminal outside a padded view gives nil, because its own frame would put the click
  /// beside the button.
  static func labelPoint(of pane: TerminalView, offset: CGFloat) -> NSPoint? {
    guard let column = PaddedTerminalView.containing(pane) else { return nil }
    let frame = column.convert(column.bounds, to: nil)
    let buttonX = frame.minX + SessionView.labelPadding + SessionView.labelWidth + SessionView.labelSpacing
    return NSPoint(x: buttonX + offset, y: frame.maxY + 9)
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
