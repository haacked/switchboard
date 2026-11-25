import AppKit

/// A scripted check of the message field's draft, run by `bin/test-gui`. SB_DRAFT_TEST=type shows the field of the
/// session that SB_SELECT selected and types into it, selects SB_DRAFT_TEST_OTHER, whose terminal view shows no
/// field, and comes back, then presses Esc once. SB_DRAFT_TEST=check reads the field after a relaunch without
/// showing it, presses Esc twice to clear it, and a third time to hide it. Each step logs what the field holds to
/// standard error, and the app quits at the end.
@MainActor
enum DraftSelfTest {
  static let typed = "draft survives a switch"

  static func start(_ model: BoardModel) {
    let env = ProcessInfo.processInfo.environment
    guard let step = env["SB_DRAFT_TEST"], let session = env["SB_SELECT"] else { return }
    Task { @MainActor in
      // The draft shows the field after a relaunch.
      if let field = await waitForField(model, session, reveal: step == "type") {
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
    guard let back = await waitForField(model, session, reveal: false) else { return }
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
    log("after two escs: field shows \(self.field() != nil)")
    escape(field)
    await pause()
    log("after a third esc: field shows \(self.field() != nil)")
  }

  static func draft(_ model: BoardModel, _ session: String) -> MessageField.Draft? {
    model.sessions.first { $0.id == session }.map(model.messageDraft)
  }

  /// Waits up to 60 s for the session to be listed and its message field drawn. With `select`, it also
  /// selects the session. Without it, the caller has shown the field some other way, such as in the Inbox. With
  /// `reveal`, it shows the field that a session's terminal view hides, as ⇧⌘E does but without moving focus.
  static func waitForField(
    _ model: BoardModel, _ session: String, select: Bool = true, reveal: Bool = false
  ) async -> NSTextField? {
    for _ in 0..<240 {
      if select, model.selection != session, model.sessions.contains(where: { $0.id == session }) {
        model.selection = session
      }
      if reveal, model.revealedMessageField != session { model.revealMessageField(session, focus: false) }
      if !select || model.selection == session, let field = field() { return field }
      try? await Task.sleep(for: .seconds(0.25))
    }
    log("no message field")
    return nil
  }

  private static func field() -> NSTextField? {
    NSApp.switchboardWindow?.contentView.flatMap { TerminalSelfTest.textField(placeholder: "Message Claude…", in: $0) }
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
