import AppKit
import SwiftTerm

/// A scripted check of the terminal panes, for comparing SwiftTerm with
/// libghostty on a Mac with no one at the keyboard. SB_TERMINAL_TEST=<folder>
/// sends the same synthetic key, paste, scroll, and resize events to the
/// leftmost pane (the Claude pane) of the selected session, then writes
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
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      await run(folder: folder)
      if ProcessInfo.processInfo.environment["SB_TERMINAL_TEST_EXIT"] != nil { NSApp.terminate(nil) }
    }
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
