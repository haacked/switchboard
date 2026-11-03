import AppKit
import SwiftTerm

/// A scripted check of the terminal panes on a Mac with no one at the keyboard. SB_TERMINAL_TEST=<folder>
/// sends synthetic key, paste, scroll, and resize events to the leftmost pane (the Claude pane) of the
/// selected session (the first one when none is selected), then writes pane.png (the pane as drawn) to the
/// folder. The pane's program reports what it received, so `sb screen` shows the result.
@MainActor
enum TerminalSelfTest {
  static func start(_ model: BoardModel) {
    guard let folder = ProcessInfo.processInfo.environment["SB_TERMINAL_TEST"] else { return }
    Task { @MainActor in
      await waitForAttach(model)
      await run(folder: folder)
      if ProcessInfo.processInfo.environment["SB_TERMINAL_TEST_EXIT"] != nil { NSApp.terminate(nil) }
    }
  }

  /// Selects the first session when none is selected. It then waits until the selected session reports
  /// a tmux client on its Claude pane, a terminal view is in the window, and the file named by
  /// SB_TERMINAL_TEST_READY exists (when that is set). The caller creates that file once the pane's
  /// program has seen the terminal's size, which `attached` alone does not show under load. The wait
  /// ends after 180 s and logs "gave up", which `bin/test-gui` treats as a failure.
  private static func waitForAttach(_ model: BoardModel) async {
    let start = Date()
    let ready = ProcessInfo.processInfo.environment["SB_TERMINAL_TEST_READY"]
    var met = false
    while Date().timeIntervalSince(start) < 180 {
      if model.selection == nil, let first = model.sessions.first { model.selection = first.id }
      let readyFileExists = ready.map { FileManager.default.fileExists(atPath: $0) } ?? true
      let attached = model.selected?.attached == true
      if readyFileExists, attached, claudePane() != nil {
        met = true
        break
      }
      await pause(0.25)
    }
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    log(met ? "attached after \(ms) ms" : "gave up waiting to attach after \(ms) ms")
    await pause(1)
  }

  private static func claudePane() -> TerminalView? {
    guard let root = NSApp.windows.first(where: { $0.isVisible && $0.title == "Switchboard" })?.contentView
    else { return nil }
    return panes(in: root).min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
  }

  private static func panes(in view: NSView) -> [TerminalView] {
    var found: [TerminalView] = []
    func walk(_ v: NSView) {
      if let terminal = v as? TerminalView {
        found.append(terminal)
      } else {
        v.subviews.forEach(walk)
      }
    }
    walk(view)
    return found
  }

  /// The key code that types `char` on the current keyboard layout, so the script
  /// works on a Dvorak keyboard too. Keys that aren't characters keep their fixed code.
  private static func code(for char: String) -> UInt16 {
    for code in UInt16(0)..<UInt16(50) {
      let probe = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
      if probe?.characters(byApplyingModifiers: []) == char { return code }
    }
    return 0
  }

  private static func key(
    _ view: NSView, _ chars: String, _ plain: String? = nil, code: UInt16, mods: NSEvent.ModifierFlags = []
  ) {
    guard let window = view.window else { return }
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      guard
        let event = NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: chars,
          charactersIgnoringModifiers: plain ?? chars,
          isARepeat: false, keyCode: code)
      else { continue }
      if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
    }
  }

  /// A modifier key on its own, which AppKit reports as flagsChanged. `flags` are the modifiers held after the change.
  private static func modifier(_ view: NSView, code: UInt16, flags: NSEvent.ModifierFlags) {
    guard let window = view.window,
      let event = NSEvent.keyEvent(
        with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: code)
    else { return }
    view.flagsChanged(with: event)
  }

  /// Marked text, a dead key, and modifier keys on their own. The checks that read the pane's state log a
  /// result here. What reaches the program shows in `sb screen`: é (c3 a9) after the dead key, and, for a
  /// program that asked for the Kitty keyboard protocol's "report all keys" level, the modifier events.
  ///
  /// Synthetic key events reach the input context, but they don't start a dead key, because the keyboard
  /// layout's state machine only runs for events from the keyboard. So the check starts the composition
  /// through the NSTextInputClient calls that an input context makes, then sends the key that finishes it
  /// with the composed character as its text.
  private static func inputMethodChecks(_ pane: TerminalView) async {
    let none = NSRange(location: NSNotFound, length: 0)
    pane.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: none)
    log("marked text set: has \(pane.hasMarkedText()) range \(pane.markedRange())")
    pane.setMarkedText(NSAttributedString(string: "日本"), selectedRange: none, replacementRange: none)
    log("marked text replaced: has \(pane.hasMarkedText()) range \(pane.markedRange())")
    log("candidate window rect \(pane.firstRect(forCharacterRange: pane.markedRange(), actualRange: nil))")
    await pause()
    if let folder = ProcessInfo.processInfo.environment["SB_TERMINAL_TEST"] {
      png(pane, to: "\(folder)/pane-preedit.png")
    }
    pane.unmarkText()
    log("marked text cleared: has \(pane.hasMarkedText()) range \(pane.markedRange())")
    await pause()

    pane.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
    log("dead key: composing \(pane.hasMarkedText())")
    key(pane, "é", "e", code: code(for: "e"))
    log("dead key then e: composing \(pane.hasMarkedText())")
    await pause()

    modifier(pane, code: 0x38, flags: .shift)
    modifier(pane, code: 0x38, flags: [])
    modifier(pane, code: 0x3B, flags: .control)
    modifier(pane, code: 0x3B, flags: [])
    // Both Shift keys, then the left one up: the right one is still held.
    modifier(pane, code: 0x38, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2))
    modifier(pane, code: 0x3C, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x6))
    modifier(pane, code: 0x38, flags: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x4))
    modifier(pane, code: 0x3C, flags: [])
    await pause()
    log("modifier keys alone: shift, control, both shifts")
  }

  private static func scroll(_ view: NSView, lines: Int32) {
    if let window = view.window,
      let move = NSEvent.mouseEvent(
        with: .mouseMoved, location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0, clickCount: 0, pressure: 0)
    {
      view.mouseMoved(with: move)
    }
    guard
      let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0),
      let event = NSEvent(cgEvent: cg)
    else { return }
    view.scrollWheel(with: event)
  }

  private static func pause(_ seconds: Double = 0.4) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
  }

  private static func png(_ view: NSView, to path: String) {
    guard let layer = view.layer, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return }
    // cacheDisplay misses the layers that SwiftTerm draws text in, so draw the layer tree.
    layer.render(in: context.cgContext)
    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }

  private static func log(_ text: String) { FileHandle.standardError.write(Data("selftest: \(text)\n".utf8)) }

  static func run(folder: String) async {
    guard let pane = claudePane() else { return log("no terminal pane") }
    pane.window?.makeFirstResponder(pane)
    log("pane \(Int(pane.bounds.width))x\(Int(pane.bounds.height))")
    await pause(1)
    png(pane, to: "\(folder)/pane-start.png")

    key(pane, "a", code: code(for: "a"))
    key(pane, "b", code: code(for: "b"))
    key(pane, "c", code: code(for: "c"))
    key(pane, "\r", code: 36)
    await pause()
    log("typed abc, return")
    key(pane, "\u{03}", "c", code: code(for: "c"), mods: .control)
    await pause()
    log("ctrl-c")
    key(pane, "∫", "b", code: code(for: "b"), mods: .option)
    await pause()
    log("option-b")
    key(pane, "\u{F700}", code: 126, mods: [.numericPad, .function])
    key(pane, "\u{F701}", code: 125, mods: [.numericPad, .function])
    key(pane, "\u{F702}", code: 123, mods: [.numericPad, .function])
    key(pane, "\u{7F}", code: 51)
    key(pane, "\u{1B}", code: 53)
    key(pane, "\t", code: 48)
    // A real keyboard reports U+0019 for Shift-Tab in both characters and charactersIgnoringModifiers.
    key(pane, "\u{19}", code: 48, mods: .shift)
    await pause()
    log("up, down, left, delete, escape, tab, shift-tab")
    key(pane, "x", code: code(for: "x"))
    await pause()
    log("x")

    await inputMethodChecks(pane)

    let board = NSPasteboard.general
    board.clearContents()
    board.setString("paste line one\npaste line two\n", forType: .string)
    pane.paste(pane)
    await pause(0.8)
    log("paste")

    scroll(pane, lines: 10)
    await pause(0.8)
    log("scroll up")

    if let window = pane.window {
      let before = window.frame
      window.setFrame(
        NSRect(x: before.minX, y: before.minY, width: before.width - 300, height: before.height - 200), display: true)
      await pause(1.5)
      log("resized -\(300)x-\(200) pane \(Int(pane.bounds.width))x\(Int(pane.bounds.height))")
      png(pane, to: "\(folder)/pane-resized.png")
      window.setFrame(before, display: true)
      await pause(1)
    }
    png(pane, to: "\(folder)/pane-end.png")
    log("done")
  }
}
