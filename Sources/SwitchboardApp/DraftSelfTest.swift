import AppKit

/// A scripted check of the message field's draft, run by `bin/test-gui`. SB_DRAFT_TEST=type types into the
/// field of the session that SB_SELECT selected, selects SB_DRAFT_TEST_OTHER and comes back, then presses Esc
/// once. SB_DRAFT_TEST=check reads the field after a relaunch, then presses Esc twice. Each step logs what the
/// field holds to standard error, and the app quits at the end.
@MainActor
enum DraftSelfTest {
  static let typed = "draft survives a switch"

  static func start(_ model: BoardModel) {
    let env = ProcessInfo.processInfo.environment
    guard let step = env["SB_DRAFT_TEST"], let session = env["SB_SELECT"] else { return }
    Task { @MainActor in
      if let field = await waitForField(model, session) {
        if step == "type" {
          await type(into: field, model, session: session, other: env["SB_DRAFT_TEST_OTHER"] ?? "")
        } else {
          await check(field, model, session: session)
        }
      }
      log("done")
      NSApp.terminate(nil)
    }
  }

  private static func type(into field: NSTextField, _ model: BoardModel, session: String, other: String) async {
    field.window?.makeFirstResponder(field)
    (field.currentEditor() as? NSTextView)?.insertText(
      typed, replacementRange: NSRange(location: NSNotFound, length: 0))
    await pause()
    log("typed: \(field.stringValue)")
    log("draft: \(draft(model, session)?.text ?? "<none>")")
    model.selection = other
    await pause()
    log("other session: \(self.field()?.stringValue ?? "<no field>")")
    model.selection = session
    // The other session's field stays in the window until SwiftUI redraws.
    await pause()
    guard let back = await waitForField(model, session) else { return }
    log("after switch: \(back.stringValue)")
    back.window?.makeFirstResponder(back)
    await pause()
    escape(back)
    await pause()
    log("after one esc: \(back.stringValue) hint \(draft(model, session)?.escapeHint == true)")
    try? await Task.sleep(for: .seconds(MessageField.Draft.escapeWindow + 0.5))
    log("hint after the window: \(draft(model, session)?.escapeHint == true)")
  }

  private static func check(_ field: NSTextField, _ model: BoardModel, session: String) async {
    log("after relaunch: \(field.stringValue)")
    field.window?.makeFirstResponder(field)
    await pause()
    escape(field)
    try? await Task.sleep(for: .seconds(0.2))
    escape(field)
    await pause()
    log("after two escs: \(field.stringValue)")
  }

  private static func draft(_ model: BoardModel, _ session: String) -> MessageField.Draft? {
    model.sessions.first { $0.id == session }.map(model.messageDraft)
  }

  /// Waits up to 60 s for the session to be listed, selected, and its message field drawn.
  private static func waitForField(_ model: BoardModel, _ session: String) async -> NSTextField? {
    for _ in 0..<240 {
      if model.selection != session, model.sessions.contains(where: { $0.id == session }) {
        model.selection = session
      }
      if model.selection == session, let field = field() { return field }
      try? await Task.sleep(for: .seconds(0.25))
    }
    log("no message field")
    return nil
  }

  private static func field() -> NSTextField? {
    guard let root = NSApp.windows.first(where: { $0.isVisible && $0.title == "Switchboard" })?.contentView
    else { return nil }
    func find(_ view: NSView) -> NSTextField? {
      if let field = view as? NSTextField, field.placeholderString == "Message Claude…" { return field }
      return view.subviews.lazy.compactMap(find).first
    }
    return find(root)
  }

  /// Sends Esc through the window, so that SwiftUI's key handlers see it as they see a typed key.
  private static func escape(_ view: NSView) {
    guard let window = view.window else { return }
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      guard
        let event = NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
          isARepeat: false, keyCode: 53)
      else { continue }
      window.sendEvent(event)
    }
  }

  private static func pause() async { try? await Task.sleep(for: .seconds(0.5)) }

  private static func log(_ text: String) { FileHandle.standardError.write(Data("drafttest: \(text)\n".utf8)) }
}
