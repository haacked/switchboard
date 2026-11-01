import AppKit
import SwiftTerm

/// A scripted check of the terminal panes, for comparing SwiftTerm with
/// libghostty on a Mac with no one at the keyboard. SB_TERMINAL_TEST=<folder>
/// sends the same synthetic key, paste, scroll, and resize events to the
/// leftmost pane (the Claude pane) of the selected session (the first one when none is selected), then writes
/// pane.png (the pane as drawn) to the folder. The pane's program reports
/// what it received, so `sb screen` shows the result.
@MainActor
enum TerminalSelfTest {
  static func start(_ model: BoardModel) {
    let env = ProcessInfo.processInfo.environment
    if let count = env["SB_TERMINAL_CYCLE"].flatMap(Int.init) {
      let seconds = Double(env["SB_TERMINAL_CYCLE_SECONDS"] ?? "1.5") ?? 1.5
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        for _ in 0..<(env["SB_TERMINAL_CYCLE_REPEAT"].flatMap(Int.init) ?? 1) {
          for session in model.sessions.prefix(count) {
            model.selection = session.id
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
          }
        }
        log("cycle done pid \(ProcessInfo.processInfo.processIdentifier) sessions \(min(count, model.sessions.count))")
      }
    }
    guard let folder = env["SB_TERMINAL_TEST"] else { return }
    Task { @MainActor in
      await waitForAttach(model)
      await run(folder: folder)
      if ProcessInfo.processInfo.environment["SB_TERMINAL_TEST_EXIT"] != nil { NSApp.terminate(nil) }
    }
  }

  /// Selects the first session when none is selected. It then waits until the selected session reports
  /// a tmux client on its Claude pane, a terminal view is in the window, and the file named by
  /// SB_TERMINAL_TEST_READY exists (when that is set). The caller creates that file once the pane's
  /// program has seen the terminal's size, which `attached` alone does not show under load. A slow
  /// start can take far longer than a fixed delay, so the wait ends after 180 s, and `run` then
  /// reports what is missing.
  private static func waitForAttach(_ model: BoardModel) async {
    let start = Date()
    let ready = ProcessInfo.processInfo.environment["SB_TERMINAL_TEST_READY"]
    while Date().timeIntervalSince(start) < 180 {
      if model.selection == nil, let first = model.sessions.first { model.selection = first.id }
      if let ready, !FileManager.default.fileExists(atPath: ready) {
        try? await Task.sleep(nanoseconds: 250_000_000)
        continue
      }
      let root = NSApp.windows.first(where: { $0.isVisible && $0.title == "Switchboard" })?.contentView
      let attached = model.selected?.attached == true
      if attached, let root, !panes(in: root).isEmpty { break }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }
    log("attached after \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    await pause(1)
  }

  private static func panes(in view: NSView) -> [NSView] {
    var found: [NSView] = []
    func walk(_ v: NSView) {
      if v is TerminalView {
        found.append(v)
      } else if String(describing: type(of: v)) == "GhosttySurfaceView" {
        found.append(v)
      } else {
        v.subviews.forEach(walk)
      }
    }
    walk(view)
    return found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
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
  private static func inputMethodChecks(_ pane: NSView) async {
    guard let client = pane as? NSTextInputClient else { return log("input: pane is not an NSTextInputClient") }
    let none = NSRange(location: NSNotFound, length: 0)
    client.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: none)
    log("marked text set: has \(client.hasMarkedText()) range \(client.markedRange())")
    client.setMarkedText(NSAttributedString(string: "日本"), selectedRange: none, replacementRange: none)
    log("marked text replaced: has \(client.hasMarkedText()) range \(client.markedRange())")
    log("candidate window rect \(client.firstRect(forCharacterRange: client.markedRange(), actualRange: nil))")
    await pause()
    if let folder = ProcessInfo.processInfo.environment["SB_TERMINAL_TEST"] {
      png(pane, to: "\(folder)/pane-preedit.png")
    }
    client.unmarkText()
    log("marked text cleared: has \(client.hasMarkedText()) range \(client.markedRange())")
    await pause()

    client.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
    log("dead key: composing \(client.hasMarkedText())")
    key(pane, "é", "e", code: code(for: "e"))
    log("dead key then e: composing \(client.hasMarkedText())")
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
    var rep: NSBitmapImageRep?
    if let layer = view.layer, let surface = layer.contents, CFGetTypeID(surface as CFTypeRef) == IOSurfaceGetTypeID() {
      let image = CIImage(ioSurface: surface as! IOSurfaceRef)
      rep = NSBitmapImageRep(ciImage: image)
    } else if let layer = view.layer, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    {
      // cacheDisplay misses the layers that SwiftTerm draws text in, so draw the layer tree.
      layer.render(in: context.cgContext)
      rep = bitmap
    }
    try? rep?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }

  private static func log(_ text: String) { FileHandle.standardError.write(Data("selftest: \(text)\n".utf8)) }

  static func run(folder: String) async {
    guard let root = NSApp.windows.first(where: { $0.isVisible && $0.title == "Switchboard" })?.contentView,
      let pane = panes(in: root).first
    else { return log("no terminal pane") }
    pane.window?.makeFirstResponder(pane)
    log("pane \(type(of: pane)) \(Int(pane.bounds.width))x\(Int(pane.bounds.height))")
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
    key(pane, "\u{19}", "\t", code: 48, mods: .shift)
    await pause()
    log("up, down, left, delete, escape, tab, shift-tab")
    key(pane, "x", code: code(for: "x"))
    await pause()
    log("x")

    await inputMethodChecks(pane)

    let board = NSPasteboard.general
    board.clearContents()
    board.setString("paste line one\npaste line two\n", forType: .string)
    if let pane = pane as? TerminalView {
      pane.paste(pane)
    } else {
      pane.tryToPerform(NSSelectorFromString("paste:"), with: pane)
    }
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
