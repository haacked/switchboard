import AppKit

/// A scripted check of Return and Shift+Return in a field that sends to Claude, run by `bin/test-gui`.
/// SB_KEY_TEST names the field by its placeholder, and SB_SELECT or SB_INBOX shows the session that holds it.
/// SB_KEY_TEST=prompt instead takes the new-session sheet's prompt editor, which SB_SHEET=new opens. That
/// editor takes Return as a new line itself.
/// In a field, the check types "one" and sets marked text as an input method does. An input method takes the
/// Return that confirms its marked text, and a script cannot run one. So a key monitor stands in for it: it logs
/// whether the Return handler would see the marked text, and keeps that Return from the field. The check then
/// confirms the marked text, presses Shift+Return, types "two", and presses Return. It posts each key to the app's
/// event queue, so SwiftUI's key handlers see it as they see a typed key. Each step logs the field's text to
/// standard error, and the app quits at the end.
@MainActor
enum KeySelfTest {
  static let prompt = "prompt"

  static func start(_ model: BoardModel) {
    let env = ProcessInfo.processInfo.environment
    guard let target = env["SB_KEY_TEST"] else { return }
    Task { @MainActor in
      if let field = await waitForField(target) {
        await run(field, model, composes: target != prompt)
      } else {
        log("no field \(target)")
      }
      log("done")
      // An open sheet keeps the app from quitting.
      model.showingNew = false
      await pause()
      NSApp.terminate(nil)
    }
  }

  /// A field that the check types into: the view that takes focus, and the text view that edits it.
  private struct Field {
    let view: NSView
    var text: String { (view as? NSTextField)?.stringValue ?? (view as? NSTextView)?.string ?? "" }
    var editor: NSTextView? { view as? NSTextView ?? (view as? NSTextField)?.currentEditor() as? NSTextView }
    var focused: Bool { editor.map { $0.window?.firstResponder === $0 } ?? false }
  }

  private static func run(_ field: Field, _ model: BoardModel, composes: Bool) async {
    // A view that sets its own focus as it appears, as the decision steps and the sheet do, can take focus back.
    for _ in 0..<5 where !field.focused {
      field.view.window?.makeFirstResponder(field.view)
      await pause()
    }
    guard field.focused, let editor = field.editor else { return log("no focus") }
    let end = NSRange(location: NSNotFound, length: 0)
    editor.insertText("one", replacementRange: end)
    if composes { await compose(editor) }
    press(field.view, modifiers: .shift)
    await pause()
    editor.insertText("two", replacementRange: end)
    await pause()
    log("shift-return: \(field.text.debugDescription)")
    if !composes { log("sheet open: \(model.showingNew)") }
    press(field.view, modifiers: [])
    // A field empties once sbd accepts what it sent, and a card's field leaves the window once its card closes.
    // The prompt keeps its text.
    for _ in 0..<(composes ? 120 : 1) where !field.text.isEmpty && field.view.window != nil {
      await pause()
    }
    log("return: \(field.text.debugDescription)")
  }

  private static func compose(_ editor: NSTextView) async {
    editor.setMarkedText(
      "x", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    let composing = Composing()
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { _ in
      MainActor.assumeIsolated { composing.seen = ReturnKey.editorIsComposing }
      return nil
    }
    press(editor, modifiers: [])
    await pause()
    monitor.map(NSEvent.removeMonitor)
    log("composing at return: \(composing.seen.map(String.init) ?? "no key")")
    editor.unmarkText()
  }

  private final class Composing { var seen: Bool? }

  /// Waits up to 60 s for the field to be drawn.
  private static func waitForField(_ target: String) async -> Field? {
    for _ in 0..<240 {
      // The main window has text views of its own. The check looks for the prompt only in the sheet.
      let window = target == prompt ? NSApp.switchboardWindow?.attachedSheet : NSApp.switchboardWindow
      if let root = window?.contentView, let view = find(target, in: root) { return Field(view: view) }
      try? await Task.sleep(for: .seconds(0.25))
    }
    return nil
  }

  private static func find(_ target: String, in view: NSView) -> NSView? {
    if target == prompt, let text = view as? NSTextView, !text.isFieldEditor, text.isEditable { return text }
    if let field = view as? NSTextField, field.placeholderString == target { return field }
    return view.subviews.lazy.compactMap { find(target, in: $0) }.first
  }

  private static func press(_ view: NSView, modifiers: NSEvent.ModifierFlags) {
    guard let window = view.window else { return }
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      guard
        let event = NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
          isARepeat: false, keyCode: 36)
      else { continue }
      NSApp.postEvent(event, atStart: false)
    }
  }

  private static func pause() async { try? await Task.sleep(for: .seconds(0.5)) }

  private static func log(_ text: String) { FileHandle.standardError.write(Data("keytest: \(text)\n".utf8)) }
}
