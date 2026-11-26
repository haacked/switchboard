import AppKit
import SwiftTerm
import SwiftUI
import SwitchboardCore

/// A scripted check of the shell pane, run by `bin/test-gui`. SB_SHELL_TEST=<folder> makes the app run each
/// command that a script writes to <folder>/cmd, one at a time. When the command is done, the app appends
/// "shelltest: <command> -> <result>" to standard error and then deletes the file. The commands are:
/// `click close` clicks the × on the Shell pane's label with mouse events at the button's place in the
/// window. `click open` clicks Open Shell on the Claude pane's label the same way. SwiftUI builds no
/// accessibility elements without an assistive app, so the test can't press a button by its label.
/// `menu <menu> <item>` runs a menu item. `titles <menu>` reports the menu's item titles, each between bars, as in
/// `|Back|Forward|`. `show-terminal` shows the terminals of an Inbox item, as its Terminal
/// toggle does. `select <session>` selects a session. `type <text>` types the text and
/// Return into the shell pane. `ctrl-d` types Ctrl-D there. `panes` reports how many terminals the window
/// shows. `cmd-w` sends ⌘W to the menu bar and reports the menu item that owns ⌘W. `nav-keys` sends each of
/// `navKeys` to the menu bar as a US keyboard types it, and reports the title of the menu item that ran.
/// `mouse <3|4>` posts a press of mouse button 4 or 5 (button numbers 3 and 4) over the window to the app's
/// event queue, so it passes through the app's event monitors as a real press does. `where` reports the place
/// that the window shows. `snapshot <path>` draws the window as SB_SNAPSHOT does. `click-row <session>` clicks the
/// session's sidebar row with mouse events at the row's place in the window. `extend-row <session>` adds the
/// session's row to the sidebar table's selection, as a ⌘-click does. `detail` reports
/// "N sessions selected" while the detail pane shows the multi-selection, else the place that the window shows.
/// `click-delete-selected` clicks Delete N Sessions… in the detail pane the same way. `sheet` reports the removal
/// sheet's step: `none`, `checking`, or `confirming <number of sessions it deletes>`. `board-click <session>
/// [count] [cmd|shift]` clicks the session's Board card `count` times, as a double click does for 2, with ⌘ or ⇧
/// held. `board-click-empty <session>` clicks the empty space just below the card. `board-drag <session>
/// <session> [cmd] [card]` drags from the empty space beside the first card, on the side that faces the second, to
/// the middle of the second. With `card`, the drag starts at the middle of the first card. The three report
/// `posted on` the hit view's type and send their events over the next half second. `board-selection` reports the
/// selected ids, sorted and joined by commas, or `none`. `drag-control` adds a draggable text view outside the
/// Board to the window, drags it the same way, and also reports `posted on`. `drags` reports how many drag
/// sessions have started since launch from the view each drag pressed or one of its superviews. `settings-key`
/// sends ⌘, to the menu bar and reports the menu item that ran, as `nav-keys` does. `settings` reports `shown
/// <tab>` while the Settings window is on screen, else `hidden`. `open-settings <tab>` opens Settings at the tab,
/// as the Issues view's gear button does. `pr-updates` reports the title and detail of Settings ▸ General's GitHub row,
/// joined by " | ". `width <points>` sets the window's content width and keeps its height. It
/// stops AppKit from saving the window's frame until `width restore` puts the frame from before the first `width`
/// back. It reports `width <content width>`, and `width restore` reports `restored`. `anchors <prefix>
/// [<container>]` scrolls each click anchor whose name starts with the prefix into view, in every window, and
/// reports `none` or the sorted names joined by commas, each followed by `:in` when the anchor lies inside its
/// window's content and inside the container anchor's frame, else `:out`. `click-anchor <name>` clicks the view
/// with that click anchor, as `click-delete-selected` does. It looks in the main window first, then in the app's other
/// windows, such as a popover's. `fill <placeholder>|<text>` types the text into the field with that placeholder,
/// in any of the app's windows. `submit <placeholder>|<text>` types the text the same way and then presses Return in
/// the field. `menu-shortcuts` checks every menu item that has a key against `AppShortcut` and reports `none`, or each
/// mismatch joined by "; ": `unlisted <title> <keys>` for an item that no entry names, `wrong <title> <keys> want
/// <keys>`, or `missing <entry>` for a menu entry that no item carries. `question [sheet]` posts a ? press to the main
/// window, or to its sheet, through the app's event queue, so the press passes through the app's key monitors as a
/// typed ? does. `overlay` reports `hidden`, or `shown` and the overlay's areas joined by commas. `toolbar` reports the
/// window toolbar's titled items in order, each followed by `:in` when the toolbar shows it or `:out` when its
/// overflow menu holds it, joined by commas. `frame <anchor>` reports the width and height of the view with that click
/// anchor in the main window, as `<width>x<height>`, or `none`.
@MainActor
enum ShellSelfTest {
  /// The shortcuts that `nav-keys` sends, in order. Search Sessions is last, because it opens a sheet. New
  /// Conversation, Message Claude, and Ask Switchboard stay out, because each one starts a conversation, moves
  /// focus into a field, or opens a sheet that `bin/test-gui shell` does not expect.
  nonisolated static let navKeys: [AppShortcut] = [
    .nextSession, .previousSession, .focusList, .focusTerminal, .back, .forward, .showRecentPlaces, .searchSessions,
  ]

  static let folder = ProcessInfo.processInfo.environment["SB_SHELL_TEST"]
  /// `board-drag` hides this view so that it can't take a card drag.
  private static var dragControl: NSView?
  /// The window's frame and autosave name from before the first `width`.
  private static var savedFrame: (frame: NSRect, name: NSWindow.FrameAutosaveName)?

  static func start(_ model: BoardModel) {
    guard let folder else { return }
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
      guard names.count == 2, let menu = refreshedMenu(names[0]) else { return "no menu" }
      let index = menu.indexOfItem(withTitle: names[1])
      guard index >= 0 else { return "not found in \(menu.items.map(\.title))" }
      guard menu.items[index].isEnabled else { return "disabled" }
      menu.performActionForItem(at: index)
      return "ran"
    case "titles":
      guard let menu = refreshedMenu(rest) else { return "no menu" }
      return "|" + menu.items.filter { !$0.isSeparatorItem }.map(\.title).joined(separator: "|") + "|"
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
      return navKeys.map { menuItem(running: $0.binding, in: window) }.joined(separator: "; ")
    case "menu-shortcuts":
      let found = menuShortcutMismatches()
      return found.isEmpty ? "none" : found.joined(separator: "; ")
    case "question":
      let target = rest == "sheet" ? window?.attachedSheet : window
      guard let target else { return "no window" }
      guard let event = keyDown("?", ignoringModifiers: "/", in: target) else { return "no event" }
      NSApp.postEvent(event, atStart: false)
      return "posted"
    case "overlay":
      guard let request = model.shortcutsOverlay else { return "hidden" }
      return "shown " + request.areas.map { "\($0)" }.joined(separator: ",")
    case "settings-key":
      guard let window else { return "no window" }
      return menuItem(running: KeyboardShortcut(","), in: window)
    case "settings":
      return model.settingsShown ? "shown \(model.settingsTab.rawValue)" : "hidden"
    case "pr-updates":
      let text = PRUpdatesRow.text(model.prSources, now: nowMs())
      return [text.title, text.detail].compactMap { $0 }.joined(separator: " | ")
    case "open-settings":
      guard let tab = SettingsTab(rawValue: rest) else { return "no tab \(rest)" }
      model.openSettings(tab)
      return "opened"
    case "mouse":
      guard let window else { return "no window" }
      guard let button = Int(rest), let event = otherMouseDown(button, in: window) else { return "no event" }
      NSApp.postEvent(event, atStart: false)
      return "posted"
    case "where":
      return "\(model.location.place)"
    case "click-row":
      return click(anchor: rest, throughWindow: true)
    case "extend-row":
      return extendSelection(to: rest)
    case "detail":
      return model.showsMultiSelectionPane
        ? DoneRemovalText.selected(model.multiSelected.count) : "\(model.location.place)"
    case "click-delete-selected":
      return click(anchor: "delete-selected", throughWindow: false)
    case "sheet":
      switch model.doneRemoval {
      case nil: return "none"
      case .checking: return "checking"
      case .confirming(let plan, _): return "confirming \(plan.remove.count)"
      }
    case "snapshot":
      Snapshot.write(to: rest)
      return "wrote"
    case "board-click":
      let args = rest.split(separator: " ").map(String.init)
      guard let id = args.first, let card = boardCard(id) else { return "no card" }
      let flags: NSEvent.ModifierFlags = args.contains("cmd") ? .command : args.contains("shift") ? .shift : []
      let point = NSPoint(x: card.minX + clickInset, y: card.maxY - clickInset)
      let count = args.dropFirst().compactMap { Int($0) }.first ?? 1
      return press(at: point, count: count, flags: flags)
    case "board-click-empty":
      guard let card = boardCard(rest) else { return "no card" }
      return press(at: NSPoint(x: card.midX, y: card.minY - 4))
    case "board-drag":
      dragControl?.isHidden = true
      let args = rest.split(separator: " ").map(String.init)
      // Scrolling the second card into view can move the first, so both frames are read after both scrolls.
      guard args.count >= 2, boardCard(args[1]) != nil, let from = boardCard(args[0]),
        let to = boardCard(args[1], scroll: false)
      else { return "no card" }
      // Without `card`, the drag starts in the gap on the side of the first card that faces the second, so it
      // crosses both.
      let gap = to.midY < from.midY ? from.maxY + 4 : from.minY - 4
      let start = NSPoint(x: from.midX, y: args.contains("card") ? from.midY : gap)
      return drag(from: start, to: NSPoint(x: to.midX, y: to.midY), flags: args.contains("cmd") ? .command : [])
    case "drag-control":
      // The control goes in the window's frame view, above every other view, so the drag hits it.
      guard let frameView = window?.contentView?.superview else { return "no window" }
      let control = NSHostingView(rootView: Text(verbatim: "drag control").padding(20).draggable("drag control"))
      control.frame = NSRect(x: frameView.bounds.midX - 80, y: frameView.bounds.midY - 30, width: 160, height: 60)
      frameView.addSubview(control, positioned: .above, relativeTo: nil)
      dragControl = control
      frameView.layoutSubtreeIfNeeded()
      let start = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
      return drag(from: start, to: NSPoint(x: start.x + 100, y: start.y + 100), flags: [])
    case "drags":
      return "\(DragWatch.sessions)"
    case "width":
      return setWidth(rest)
    case "anchors":
      let args = rest.split(separator: " ").map(String.init)
      guard let prefix = args.first else { return "no prefix" }
      return anchors(prefix: prefix, container: args.count > 1 ? args[1] : nil)
    case "click-anchor":
      return click(anchor: rest, throughWindow: false)
    case "fill", "submit":
      let parts = rest.split(separator: "|", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { return "\(words[0]) needs <placeholder>|<text>" }
      return fill(placeholder: parts[0], with: parts[1], submit: words[0] == "submit")
    case "board-selection":
      let ids = model.multiSelection.sorted()
      return ids.isEmpty ? "none" : ids.joined(separator: ",")
    case "toolbar":
      guard let toolbar = window?.toolbar else { return "no toolbar" }
      let visible = Set((toolbar.visibleItems ?? []).map(ObjectIdentifier.init))
      return toolbarReport(
        toolbar.items.map { (title: title(of: $0), visible: visible.contains(ObjectIdentifier($0))) })
    case "frame":
      guard let root = window?.contentView, let anchor = ClickAnchorView.find(rest, in: root) else { return "none" }
      return size(anchor.bounds)
    default:
      return "unknown command"
    }
  }

  /// The actions of the items that macOS adds to the Edit menu. Their keys use the Globe key, which a
  /// `KeyboardShortcut` can't name.
  private static let systemActions: Set<Selector> = [
    Selector(("startDictation:")), #selector(NSApplication.orderFrontCharacterPalette(_:)),
  ]

  private static let modifierPairs: [(NSEvent.ModifierFlags, EventModifiers)] = [
    (.command, .command), (.option, .option), (.shift, .shift), (.control, .control),
  ]

  private static func menuShortcutMismatches() -> [String] {
    let entries = AppShortcut.available.filter { $0.kind == .menu || $0.kind == .menuAlternate }
    var found: [String] = []
    var carried: Set<AppShortcut> = []
    let menus = (NSApp.mainMenu?.items ?? []).compactMap { $0.submenu.map { refreshedMenu($0.title) ?? $0 } }
    for item in menus.flatMap(\.items) {
      guard let key = item.keyEquivalent.first, !(item.action.map(systemActions.contains) ?? false) else { continue }
      let mask = item.keyEquivalentModifierMask
      let press = AppShortcut.Press(key, EventModifiers(Self.modifierPairs.filter { mask.contains($0.0) }.map(\.1)))
      let keys = AppShortcut.glyphs(KeyboardShortcut(KeyEquivalent(press.key), modifiers: press.modifiers))
      guard let entry = AppShortcut.entry(menuTitle: item.title) else {
        if !AppShortcut.systemPresses.contains(press) { found.append("unlisted \(item.title) \(keys)") }
        continue
      }
      carried.insert(entry)
      if press != AppShortcut.Press(entry.keys[0]) {
        found.append("wrong \(item.title) \(keys) want \(AppShortcut.glyphs(entry.keys[0]))")
      }
    }
    return found + entries.filter { !carried.contains($0) }.map { "missing \($0)" }
  }

  /// The menu bar's menu with `title`. SwiftUI sets the items' titles when the menu opens. This function asks for
  /// them first.
  private static func refreshedMenu(_ title: String) -> NSMenu? {
    guard let menu = NSApp.mainMenu?.item(withTitle: title)?.submenu else { return nil }
    menu.delegate?.menuNeedsUpdate?(menu)
    menu.update()
    return menu
  }

  /// The frame of the session's Board card in window coordinates, after the Board scrolls the card and 24 pt
  /// around it into view. The commands click and drag in the space just outside the card.
  private static func boardCard(_ id: String, scroll: Bool = true) -> NSRect? {
    guard let root = window?.contentView, let anchor = ClickAnchorView.find("board-card-\(id)", in: root) else {
      return nil
    }
    if scroll { anchor.scrollToVisible(anchor.bounds.insetBy(dx: 0, dy: -24)) }
    root.layoutSubtreeIfNeeded()
    return anchor.convert(anchor.bounds, to: nil)
  }

  private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags) -> NSEvent? {
    guard let window else { return nil }
    return NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
  }

  /// The view that the window hits at `point`.
  private static func hitView(at point: NSPoint) -> NSView? {
    guard let root = window?.contentView else { return nil }
    return (root.superview ?? root).hitTest(point)
  }

  /// Makes the views of `view`'s class take a first click, for the rest of the process. A hidden launch never
  /// makes its window key, and a window that is not key drops a first click on a view that does not take one.
  /// SwiftUI takes a first click on a Button but not on a gesture, such as the one on empty Board space.
  private static func acceptFirstMouse(_ view: NSView) {
    let block: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
    class_replaceMethod(
      type(of: view), #selector(NSView.acceptsFirstMouse(for:)), imp_implementationWithBlock(block), "c@:@")
  }

  /// Clicks `count` times at `point` through the window. The clicks are 0.1 s apart, so each one's mouse-up is
  /// handled before the next mouse-down.
  private static func press(at point: NSPoint, count: Int = 1, flags: NSEvent.ModifierFlags = []) -> String {
    guard let window, let view = hitView(at: point) else { return "nothing at \(Int(point.x)),\(Int(point.y))" }
    acceptFirstMouse(view)
    Task { @MainActor in
      for n in 1...max(count, 1) {
        TerminalSelfTest.click(at: point, in: window, count: n, flags: flags)
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    return "posted on \(type(of: view))"
  }

  /// Presses at `start`, drags to `end` in ten steps, and lets go, through the window.
  private static func drag(from start: NSPoint, to end: NSPoint, flags: NSEvent.ModifierFlags) -> String {
    guard let view = hitView(at: start) else { return "nothing at \(Int(start.x)),\(Int(start.y))" }
    acceptFirstMouse(view)
    DragWatch.watch(view)
    Task { @MainActor in
      guard let down = mouse(.leftMouseDown, at: start, flags: flags) else { return }
      window?.sendEvent(down)
      for step in 1...10 {
        try? await Task.sleep(for: .milliseconds(30))
        let t = CGFloat(step) / 10
        let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        if let moved = mouse(.leftMouseDragged, at: point, flags: flags) { window?.sendEvent(moved) }
      }
      try? await Task.sleep(for: .milliseconds(30))
      if let up = mouse(.leftMouseUp, at: end, flags: flags) { window?.sendEvent(up) }
    }
    return "posted on \(type(of: view))"
  }

  /// How far into its leading edge `click(anchor:)` clicks a view: past a row's padding, onto a button's icon.
  private static let clickInset: CGFloat = 12

  /// Clicks `clickInset` pt into the leading edge of the view whose `clickAnchor` is `name`, at its vertical
  /// middle, and reports the type of the view that the window hits there. Without `throughWindow`, the mouse-down
  /// goes to that view. A window that is not key drops a first click on a button, and a hidden launch never makes
  /// its window key. A sidebar row needs the window, because the window's handling of the mouse-down selects the row.
  private static func click(anchor name: String, throughWindow: Bool) -> String {
    guard let main = window?.contentView else { return "no window" }
    guard
      let anchor = roots.lazy.compactMap({ ClickAnchorView.find(name, in: $0) }).first
        ?? scrollIntoView(name, in: main),
      let window = anchor.window, let root = window.contentView
    else { return "no \(name)" }
    // A row near the edge of the sidebar can be built but partly hidden under another view.
    anchor.scrollToVisible(anchor.bounds)
    root.layoutSubtreeIfNeeded()
    let frame = anchor.convert(anchor.bounds, to: nil)
    let point = NSPoint(x: frame.minX + clickInset, y: frame.midY)
    guard let hit = (root.superview ?? root).hitTest(point) else {
      let frameView = root.superview ?? root
      return "nothing at \(name) (\(Int(point.x)),\(Int(point.y)) in a window of \(size(frameView.frame)), content "
        + "\(size(root.frame)) at \(Int(root.frame.minX)),\(Int(root.frame.minY)))"
    }
    if let row = enclosingRow(of: anchor), !hit.isDescendant(of: row) {
      return "\(type(of: hit)) covers \(name)"
    }
    guard TerminalSelfTest.click(at: point, in: window, on: throughWindow ? nil : hit) else {
      return "no event"
    }
    return "clicked at \(Int(point.x)),\(Int(point.y)) on \(type(of: hit))"
  }

  /// Types `text` into the text field whose placeholder is `placeholder`, in any of the app's windows, as an input
  /// method inserts it. With `submit`, it then presses Return in the field.
  private static func fill(placeholder: String, with text: String, submit: Bool) -> String {
    guard let field = roots.lazy.compactMap({ TerminalSelfTest.textField(placeholder: placeholder, in: $0) }).first
    else { return "no field \(placeholder)" }
    guard field.window?.makeFirstResponder(field) == true, let editor = field.currentEditor() as? NSTextView else {
      return "no focus"
    }
    editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    guard submit else { return "filled" }
    // The field editor ends editing on a new line, and the field then runs its SwiftUI onSubmit.
    editor.insertNewline(nil)
    return "submitted"
  }

  private static func setWidth(_ arg: String) -> String {
    guard let window else { return "no window" }
    if arg == "restore" {
      guard let saved = savedFrame else { return "restored" }
      // Setting the name saves the frame at once. The frame has to go back first.
      window.setFrame(saved.frame, display: true)
      window.setFrameAutosaveName(saved.name)
      savedFrame = nil
      return "restored"
    }
    guard let width = Double(arg), width > 0 else { return "no width" }
    if savedFrame == nil {
      savedFrame = (window.frame, window.frameAutosaveName)
      // AppKit saves the main window's frame on every change. A killed app would keep the test's width.
      window.setFrameAutosaveName("")
    }
    let height = window.contentView?.frame.height ?? window.frame.height
    window.setContentSize(NSSize(width: width, height: height))
    window.contentView?.layoutSubtreeIfNeeded()
    return "width \(Int(window.contentView?.frame.width ?? 0))"
  }

  private static func anchors(prefix: String, container: String?) -> String {
    var found: [String] = []
    for root in roots {
      // The frame view is the window's whole area. A content view can be larger than it, and a click outside it
      // hits nothing.
      let frameView = root.superview ?? root
      let bounds = root.convert(root.bounds, to: nil).intersection(frameView.convert(frameView.bounds, to: nil))
      let box = container.flatMap { ClickAnchorView.find($0, in: root) }
      for anchor in ClickAnchorView.all(prefix: prefix, in: root) {
        anchor.scrollToVisible(anchor.bounds)
        root.layoutSubtreeIfNeeded()
        let frame = anchor.convert(anchor.bounds, to: nil)
        // A container that the window doesn't hold puts every anchor out.
        let inside =
          (container == nil || box != nil)
          && anchorIsInside(frame, window: bounds, container: box.map { $0.convert($0.bounds, to: nil) })
        found.append("\(anchor.name):\(inside ? "in" : "out")")
      }
    }
    return found.isEmpty ? "none" : found.sorted().joined(separator: ",")
  }

  static func toolbarReport(_ items: [(title: String?, visible: Bool)]) -> String {
    items.compactMap { item in
      guard let title = item.title, !title.isEmpty else { return nil }
      return "\(title):\(item.visible ? "in" : "out")"
    }.joined(separator: ",")
  }

  /// SwiftUI leaves some items' labels empty, and then only the hosted view's accessibility label names the item. A
  /// spacer has only a palette label, so it reports no title.
  private static func title(of item: NSToolbarItem) -> String? {
    [item.label, item.view?.accessibilityLabel() ?? ""].first { !$0.isEmpty }
  }

  private static func size(_ rect: NSRect) -> String { "\(Int(rect.width))x\(Int(rect.height))" }

  /// Whether `frame` lies inside the window's content and inside the container, give or take 1 pt for rounding.
  static func anchorIsInside(_ frame: NSRect, window: NSRect, container: NSRect?) -> Bool {
    [window, container].compactMap { $0 }.allSatisfy { $0.insetBy(dx: -1, dy: -1).contains(frame) }
  }

  /// Adds the table row that holds the anchor named `name` to that table's selection. A posted ⌘-click
  /// replaces a List's selection on macOS 26 instead of extending it, so the step uses the table's own
  /// selection call. The table reports the change to SwiftUI the way it reports a ⌘-click.
  private static func extendSelection(to name: String) -> String {
    guard let root = window?.contentView else { return "no window" }
    guard let anchor = ClickAnchorView.find(name, in: root) ?? scrollIntoView(name, in: root) else {
      return "no \(name)"
    }
    var next = anchor.superview
    while let v = next, !(v is NSTableView) { next = v.superview }
    guard let table = next as? NSTableView else { return "\(name) is not in a table" }
    let row = table.row(for: anchor)
    guard row >= 0 else { return "\(name) has no row" }
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
    return "selected row \(row)"
  }

  /// The anchor named `name` in a row of a table under `view`, after that table scrolls the row into view. A
  /// SwiftUI List builds views only for the rows near its visible area.
  private static func scrollIntoView(_ name: String, in view: NSView) -> ClickAnchorView? {
    for table in tables(in: view) {
      for row in 0..<table.numberOfRows {
        table.scrollRowToVisible(row)
        table.layoutSubtreeIfNeeded()
        if let rowView = table.rowView(atRow: row, makeIfNecessary: true),
          let anchor = ClickAnchorView.find(name, in: rowView)
        {
          return anchor
        }
      }
    }
    return nil
  }

  private static func enclosingRow(of view: NSView) -> NSTableRowView? {
    var next = view.superview
    while let v = next, !(v is NSTableRowView) { next = v.superview }
    return next as? NSTableRowView
  }

  private static func tables(in view: NSView) -> [NSTableView] {
    (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
  }

  /// A key press of `char` in `window`, with ⇧ added when a US keyboard types `char` with ⇧.
  private static func keyDown(
    _ char: String, ignoringModifiers: String? = nil, flags: NSEvent.ModifierFlags = [], in window: NSWindow
  ) -> NSEvent? {
    let (code, shift) = TerminalSelfTest.keystroke(for: char)
    return NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: shift ? flags.union(.shift) : flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
      characters: char, charactersIgnoringModifiers: ignoringModifiers ?? char, isARepeat: false, keyCode: code)
  }

  /// Reports the menu item that `shortcut` runs. When none runs, it reports the item that owns the key and
  /// whether that item is enabled. The event has ⇧ when the character is a shifted one, such as "}", because
  /// a keyboard sends ⇧⌘] that way.
  private static func menuItem(running shortcut: KeyboardShortcut, in window: NSWindow) -> String {
    let char = String(shortcut.key.character)
    guard let event = keyDown(char, flags: .command, in: window) else { return "\(char) no event" }
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

  /// The content views of the app's windows, the main window's first. A popover draws in a window of its own.
  private static var roots: [NSView] {
    let main = window?.contentView
    return [main].compactMap { $0 } + NSApp.windows.compactMap(\.contentView).filter { $0 !== main }
  }

  private static func panes() -> [TerminalView] { TerminalSelfTest.panes() }

  /// The right terminal, when the window shows two.
  private static func shellPane() -> TerminalView? {
    let panes = panes()
    return panes.count == 2 ? panes.last : nil
  }

  private static func log(_ text: String) { FileHandle.standardError.write(Data("shelltest: \(text)\n".utf8)) }
}

extension View {
  /// Puts a `ClickAnchorView` named `name` behind this view while SB_SHELL_TEST runs, so ShellSelfTest can click
  /// this view at its place in the window. SwiftUI builds no accessibility elements without an assistive app.
  @ViewBuilder func clickAnchor(_ name: String) -> some View {
    if ShellSelfTest.folder != nil { background(ClickAnchor(name: name)) } else { self }
  }
}

private struct ClickAnchor: NSViewRepresentable {
  let name: String

  func makeNSView(context: Context) -> ClickAnchorView { ClickAnchorView() }

  func updateNSView(_ view: ClickAnchorView, context: Context) { view.name = name }
}

/// An empty view with the frame of the view that it is the background of.
final class ClickAnchorView: NSView {
  var name = ""

  /// The anchored view gets every click.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  static func all(prefix: String, in view: NSView) -> [ClickAnchorView] {
    let mine = (view as? ClickAnchorView).flatMap { $0.name.hasPrefix(prefix) ? [$0] : nil } ?? []
    return mine + view.subviews.flatMap { all(prefix: prefix, in: $0) }
  }

  static func find(_ name: String, in view: NSView) -> ClickAnchorView? {
    if let anchor = view as? ClickAnchorView, anchor.name == name { return anchor }
    for subview in view.subviews {
      if let found = find(name, in: subview) { return found }
    }
    return nil
  }
}

/// Counts the drag sessions that views start. It hooks `beginDraggingSession(with:event:source:)` on the class of a
/// view and of each of its superviews, because SwiftUI starts the session on a hosting view, which overrides
/// the method.
@MainActor
private enum DragWatch {
  static var sessions = 0
  private static var hooked: Set<ObjectIdentifier> = []

  static func watch(_ view: NSView?) {
    var next = view
    while let view = next {
      hook(type(of: view))
      next = view.superview
    }
  }

  private static func hook(_ cls: AnyClass) {
    guard hooked.insert(ObjectIdentifier(cls)).inserted else { return }
    let selector = #selector(NSView.beginDraggingSession(with:event:source:))
    guard let method = class_getInstanceMethod(cls, selector) else { return }
    typealias Begin =
      @convention(c) (NSView, Selector, [NSDraggingItem], NSEvent, NSDraggingSource) -> NSDraggingSession
    let original = unsafeBitCast(method_getImplementation(method), to: Begin.self)
    let block: @convention(block) (NSView, [NSDraggingItem], NSEvent, NSDraggingSource) -> NSDraggingSession = {
      view, items, event, source in
      MainActor.assumeIsolated { sessions += 1 }
      return original(view, selector, items, event, source)
    }
    class_replaceMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
  }
}
