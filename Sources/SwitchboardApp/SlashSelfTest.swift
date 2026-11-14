import AppKit

/// A scripted check of the slash command list in the message field of the session that SB_SELECT selects, run by
/// `bin/test-gui` with SB_SLASH_TEST=1. The session's folder holds `probe-repo`'s commands and skills. The check
/// types into the field and posts each key to the app's event queue, so SwiftUI's key handlers see it as they see
/// a typed key. Each step logs the field's text and the panel's rows to standard error, and the app quits at the end.
@MainActor
enum SlashSelfTest {
  static let probeRows = ["probe-cmd-plain", "probe-cmd-user-only", "probe-default", "probe-user-only"]

  static func start(_ model: BoardModel) {
    let env = ProcessInfo.processInfo.environment
    guard env["SB_SLASH_TEST"] != nil, let session = env["SB_SELECT"] else { return }
    Task { @MainActor in
      if let field = await DraftSelfTest.waitForField(model, session) {
        await run(field, model, session: session)
      }
      log("done")
      NSApp.terminate(nil)
    }
  }

  private static func run(_ field: NSTextField, _ model: BoardModel, session: String) async {
    field.window?.makeFirstResponder(field)
    await pause()
    guard let editor = field.currentEditor() as? NSTextView else { return log("no focus") }
    let focused = { editor.window?.firstResponder === editor }
    func type(_ text: String) async {
      editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
      await pause()
    }
    func clear() async {
      editor.selectAll(nil)
      editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
      await pause()
    }

    await type("/")
    log("slash: open \(panel()?.isVisible == true) rows \(!(panel()?.rows.isEmpty ?? true)) focused \(focused())")
    await type("probe-")
    // The rows that sbd read replace the built-in rows when its answer arrives.
    for _ in 0..<120 where rows() != probeRows { await pause() }
    log("probe-: \(rows().joined(separator: " ")) focused \(focused())")
    press(field, .down)
    await pause()
    press(field, .tab)
    await pause()
    let cursor = editor.selectedRange()
    log(
      "down, tab: \(field.stringValue.debugDescription) open \(panel()?.isVisible == true) focused \(focused())"
        + " cursor at end \(cursor.length == 0 && cursor.location == (field.stringValue as NSString).length)")

    await clear()
    await type("/probe-d")
    press(field, .return)
    await pause()
    log("return on /probe-d: \(field.stringValue.debugDescription) open \(panel()?.isVisible == true)")
    press(field, .return)
    await waitForSend(field)
    log("return again: \(field.stringValue.debugDescription)")

    // Keypad Enter reaches `onSubmit`, not the Return key handler.
    await type("/probe-d")
    press(field, .enter)
    await pause()
    log(
      "enter on /probe-d: \(field.stringValue.debugDescription) open \(panel()?.isVisible == true) focused \(focused())"
    )
    press(field, .enter)
    await waitForSend(field)
    log("enter again: \(field.stringValue.debugDescription)")

    await type("/probe-user-only")
    log("exact name: open \(panel()?.isVisible == true) rows \(rows().joined(separator: " "))")
    press(field, .return)
    await pause()
    log("return on the exact name: open \(panel()?.isVisible == true)")
    await waitForSend(field)
    log("sent: \(field.stringValue.debugDescription)")

    await type("/co")
    log("/co: open \(panel()?.isVisible == true)")
    press(field, .escape)
    await pause()
    let hint = DraftSelfTest.draft(model, session)?.escapeHint == true
    log("esc on /co: \(field.stringValue.debugDescription) open \(panel()?.isVisible == true) hint \(hint)")
    press(field, .escape)
    try? await Task.sleep(for: .seconds(0.2))
    press(field, .escape)
    await pause()
    log("two more escs: \(field.stringValue.debugDescription)")

    // A held key accepts on its down press. Its repeats neither send nor move focus. Tab goes last, because a Tab
    // that moves focus would break the steps after it.
    for key in [Key.return, .enter, .tab] {
      await type("/probe-d")
      press(field, key, repeats: 3)
      await pause()
      await pause()
      log("held \(key) on /probe-d: \(field.stringValue.debugDescription) focused \(focused())")
      await clear()
    }
  }

  /// A field empties once sbd accepts what it sent.
  private static func waitForSend(_ field: NSTextField) async {
    for _ in 0..<120 where !field.stringValue.isEmpty { await pause() }
  }

  /// The open panel of a message field in the window, if any.
  private static func panel() -> SlashCompletionPanel? {
    func find(_ view: NSView) -> SlashCompletionPanel? {
      if let anchor = view as? SlashCompletionAnchorView, anchor.panel.isVisible { return anchor.panel }
      return view.subviews.lazy.compactMap(find).first
    }
    return NSApp.switchboardWindow?.contentView.flatMap(find)
  }

  private static func rows() -> [String] { panel()?.rows.map(\.name) ?? [] }

  private enum Key {
    case down, tab, `return`, enter, escape
  }

  /// Posts the key's down press, `repeats` auto-repeats of it, and its release.
  private static func press(_ view: NSView, _ key: Key, repeats: Int = 0) {
    guard let window = view.window else { return }
    let (characters, code, flags): (String, UInt16, NSEvent.ModifierFlags) =
      switch key {
      case .down: ("\u{F701}", 125, [.numericPad, .function])
      case .tab: ("\t", 48, [])
      case .return: ("\r", 36, [])
      case .enter: ("\u{3}", 76, [.numericPad])
      case .escape: ("\u{1b}", 53, [])
      }
    let presses =
      [(NSEvent.EventType.keyDown, false)] + Array(repeating: (.keyDown, true), count: repeats) + [(.keyUp, false)]
    for (type, isRepeat) in presses {
      guard
        let event = NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: code)
      else { continue }
      NSApp.postEvent(event, atStart: false)
    }
  }

  private static func pause() async { try? await Task.sleep(for: .seconds(0.5)) }

  private static func log(_ text: String) { FileHandle.standardError.write(Data("slashtest: \(text)\n".utf8)) }
}
