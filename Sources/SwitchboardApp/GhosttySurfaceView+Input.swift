#if SB_GHOSTTY
  import AppKit
  import Carbon.HIToolbox
  import GhosttyKit

  // Keyboard and text input for the Ghostty pane. The flow follows the one in Ghostty's own macOS app
  // (macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift, MIT): keyDown first lets the input
  // context see the event through interpretKeyEvents, which calls setMarkedText, insertText, or
  // doCommand. Then the view sends libghostty the key event, with the committed text when there is any.

  extension GhosttySurfaceView {
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
      var mods = GHOSTTY_MODS_NONE.rawValue
      if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
      if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
      if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
      if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
      if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
      let raw = flags.rawValue
      if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
      if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
      if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
      if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
      return ghostty_input_mods_e(mods)
    }

    /// The modifiers that change the text a key types. The config's `macos-option-as-alt` decides this:
    /// with it on, Option is not one of them, so Option-E is Alt-E and not a dead key.
    private func translationFlags(for event: NSEvent) -> NSEvent.ModifierFlags {
      guard let surface else { return event.modifierFlags }
      let kept = ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags))
      var flags: NSEvent.ModifierFlags = []
      for (flag, bit) in [
        (NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL), (.option, GHOSTTY_MODS_ALT),
        (.command, GHOSTTY_MODS_SUPER),
      ] where kept.rawValue & bit.rawValue != 0 {
        flags.insert(flag)
      }
      return KeyTranslation.apply(to: event.modifierFlags, keeping: flags)
    }

    private func send(
      _ action: ghostty_input_action_e, _ event: NSEvent, translated: NSEvent.ModifierFlags, text: String? = nil,
      composing: Bool = false
    ) {
      guard let surface else { return }
      var key = ghostty_input_key_s()
      key.action = action
      key.keycode = UInt32(event.keyCode)
      key.mods = Self.mods(event.modifierFlags)
      // Control and Command never change the text a key types.
      key.consumed_mods = Self.mods(translated.subtracting([.control, .command]))
      key.composing = composing
      // characters(byApplyingModifiers:) raises an exception on a flagsChanged event.
      if event.type == .keyDown || event.type == .keyUp {
        key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
      }
      if let text {
        text.withCString {
          key.text = $0
          _ = ghostty_surface_key(surface, key)
        }
      } else {
        _ = ghostty_surface_key(surface, key)
      }
    }

    override func keyDown(with event: NSEvent) {
      guard surface != nil else {
        interpretKeyEvents([event])
        return
      }
      let translated = translationFlags(for: event)
      // AppKit keeps state that dead keys read from the event, so the original event goes to the input
      // context whenever the translation changes nothing.
      let translationEvent =
        translated == event.modifierFlags
        ? event
        : NSEvent.keyEvent(
          with: event.type, location: event.locationInWindow, modifierFlags: translated, timestamp: event.timestamp,
          windowNumber: event.windowNumber, context: nil,
          characters: event.characters(byApplyingModifiers: translated) ?? "",
          charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: event.isARepeat,
          keyCode: event.keyCode) ?? event

      keyTexts = []
      defer { keyTexts = nil }
      let markedBefore = marked.hasMarkedText
      // Some key events switch the input source, such as Control-Space. The terminal must not see them.
      let sourceBefore = markedBefore ? nil : Self.inputSourceID()
      interpretKeyEvents([translationEvent])
      if !markedBefore, Self.inputSourceID() != sourceBefore { return }
      syncPreedit(clearIfNeeded: markedBefore)

      let dispatch = KeyDispatch(
        committed: keyTexts ?? [],
        typed: KeyDispatch.sendable(
          KeyDispatch.typedText(
            translationEvent.characters(byApplyingModifiers: translated),
            withoutControl: { event.characters(byApplyingModifiers: translated.subtracting(.control)) })),
        markedBefore: markedBefore, markedAfter: marked.hasMarkedText)
      let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
      for text in dispatch.texts {
        send(action, event, translated: translated, text: text, composing: dispatch.composing)
      }
    }

    override func keyUp(with event: NSEvent) {
      send(GHOSTTY_ACTION_RELEASE, event, translated: translationFlags(for: event))
    }

    /// Shift, Control, Option, Command, and Caps Lock alone. A program that asked for the Kitty keyboard
    /// protocol's "report all keys" level gets them as key events.
    override func flagsChanged(with event: NSEvent) {
      // The modifiers that start a composition are not key events for the terminal.
      guard !marked.hasMarkedText, let action = ModifierKey.action(keyCode: event.keyCode, flags: event.modifierFlags)
      else { return }
      send(
        action == .press ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event, translated: [])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      guard event.type == .keyDown, window?.firstResponder === self, !marked.hasMarkedText,
        let characters = KeyEquivalent.terminalCharacters(
          charactersIgnoringModifiers: event.charactersIgnoringModifiers, flags: event.modifierFlags),
        let replacement = NSEvent.keyEvent(
          with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
          timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: event.isARepeat, keyCode: event.keyCode)
      else { return false }
      keyDown(with: replacement)
      return true
    }

    private static func inputSourceID() -> String? {
      guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
        let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
      else { return nil }
      return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// Tells libghostty what to draw as the composition, or to draw none.
    private func syncPreedit(clearIfNeeded: Bool = true) {
      guard let surface else { return }
      if marked.hasMarkedText {
        marked.text.withCString { ghostty_surface_preedit(surface, $0, UInt(marked.text.utf8.count)) }
      } else if clearIfNeeded {
        ghostty_surface_preedit(surface, nil, 0)
      }
    }

    /// Ends a composition that the user abandoned, such as by clicking another pane.
    func discardComposition() {
      guard marked.hasMarkedText else { return }
      inputContext?.discardMarkedText()
      unmarkText()
    }
  }

  extension GhosttySurfaceView: NSTextInputClient {
    func hasMarkedText() -> Bool { marked.hasMarkedText }

    func markedRange() -> NSRange { marked.markedRange }

    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
      guard marked.set(string) else { return }
      // Outside a keyDown, such as when the keyboard layout changes mid-composition, nothing else would
      // update the preedit.
      if keyTexts == nil { syncPreedit() }
    }

    func unmarkText() {
      guard marked.hasMarkedText else { return }
      marked.clear()
      syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
      nil
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Where the candidate window opens: the cell under the cursor, in screen coordinates.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
      guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
      var x = 0.0
      var y = 0.0
      var width = 0.0
      var height = 0.0
      ghostty_surface_ime_point(surface, &x, &y, &width, &height)
      let inWindow = convert(
        IMEGeometry.viewRect(x: x, y: y, width: width, height: height, viewHeight: bounds.height), to: nil)
      return window?.convertToScreen(inWindow) ?? inWindow
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
      // Outside a keyDown, AppKit also calls this without an event, so only an event starts text from there.
      guard keyTexts != nil || NSApp.currentEvent != nil, let text = MarkedText.string(from: string) else { return }
      // Inserting text ends the composition.
      unmarkText()
      if keyTexts != nil {
        keyTexts?.append(text)
      } else if let surface {
        // Text that arrives with no key-down, such as from the emoji picker or dictation.
        text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
      }
    }

    /// Swallows the editing commands that interpretKeyEvents reports, such as insertNewline. Without
    /// this, AppKit beeps. keyDown still sends the key itself, so libghostty encodes it.
    override func doCommand(by selector: Selector) {}
  }
#endif
