#if SB_GHOSTTY
  import AppKit
  import GhosttyKit
  import SwiftUI

  /// The one libghostty app for the process: its config (the user's Ghostty
  /// config files) and its runtime callbacks.
  @MainActor
  final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?

    private init() {
      Self.pointToResources()
      guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
        Self.log("ghostty_init failed")
        return
      }
      guard let config = ghostty_config_new() else { return }
      // Switchboard's defaults come first, so the user's Ghostty config overrides them.
      let defaults = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-ghostty-defaults.conf")
      try? "macos-option-as-alt = true\n".write(to: defaults, atomically: true, encoding: .utf8)
      defaults.path.withCString { ghostty_config_load_file(config, $0) }
      ghostty_config_load_default_files(config)
      ghostty_config_load_recursive_files(config)
      // An initial-command in the user's config would replace the tmux attach command of the first pane.
      let reset = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-ghostty-reset.conf")
      try? "initial-command =\n".write(to: reset, atomically: true, encoding: .utf8)
      reset.path.withCString { ghostty_config_load_file(config, $0) }
      // Extra settings for a run, such as window-vsync = false on a Mac with no display awake.
      if let extra = ProcessInfo.processInfo.environment["SB_GHOSTTY_CONFIG"] {
        extra.withCString { ghostty_config_load_file(config, $0) }
      }
      ghostty_config_finalize(config)
      for i in 0..<ghostty_config_diagnostics_count(config) {
        Self.log("config: \(String(cString: ghostty_config_get_diagnostic(config, i).message))")
      }

      var runtime = ghostty_runtime_config_s(
        userdata: Unmanaged.passUnretained(self).toOpaque(),
        supports_selection_clipboard: false,
        wakeup_cb: { userdata in
          guard let userdata else { return }
          let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata)
          DispatchQueue.main.async { MainActor.assumeIsolated { runtime.takeUnretainedValue().tick() } }
        },
        action_cb: { _, _, _ in false },
        read_clipboard_cb: { userdata, _, state in
          guard let view = GhosttySurfaceView.from(userdata), let surface = view.surface,
            let text = NSPasteboard.general.string(forType: .string)
          else { return false }
          text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, false) }
          return true
        },
        confirm_read_clipboard_cb: { userdata, text, state, request in
          guard let view = GhosttySurfaceView.from(userdata), let surface = view.surface, let text else { return }
          // A program that asks to read the clipboard (OSC 52) gets an empty answer. A paste is approved, as in SwiftTerm.
          let isPaste = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
          if isPaste {
            ghostty_surface_complete_clipboard_request(surface, text, state, true)
          } else {
            "".withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, true) }
          }
        },
        write_clipboard_cb: { _, _, content, count, _ in
          guard let content, count > 0 else { return }
          for i in 0..<count {
            guard let mime = content[i].mime, String(cString: mime) == "text/plain", let data = content[i].data else {
              continue
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(cString: data), forType: .string)
            return
          }
        },
        close_surface_cb: { _, _ in }
      )
      app = ghostty_app_new(&runtime, config)
      ghostty_config_free(config)
      if app == nil { Self.log("ghostty_app_new failed") }

      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.app.map { ghostty_app_set_focus($0, true) } }
      }
      NotificationCenter.default.addObserver(
        forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
      ) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.app.map { ghostty_app_set_focus($0, false) } }
      }
    }

    private func tick() {
      if let app { ghostty_app_tick(app) }
    }

    static func log(_ message: String) {
      FileHandle.standardError.write(Data("ghostty: \(message)\n".utf8))
    }

    /// Ghostty finds its terminfo and shell integration through GHOSTTY_RESOURCES_DIR. Without it the child gets
    /// TERM=xterm-256color. An app bundle would carry the folder; a development build finds it in .build/ghostty.
    private static func pointToResources() {
      if getenv("GHOSTTY_RESOURCES_DIR") != nil { return }
      var candidates = [Bundle.main.resourceURL?.appendingPathComponent("ghostty")]
      var dir = Bundle.main.executableURL?.deletingLastPathComponent()
      for _ in 0..<6 {
        candidates.append(dir?.appendingPathComponent(".build/ghostty/share/ghostty"))
        dir = dir?.deletingLastPathComponent()
      }
      for case let url? in candidates
      where FileManager.default.fileExists(atPath: url.appendingPathComponent("themes").path) {
        setenv("GHOSTTY_RESOURCES_DIR", url.path, 1)
        return
      }
    }
  }

  /// One libghostty surface. The surface exists from the moment the view enters
  /// a window until `close()`, so a session that isn't on screen holds no
  /// renderer and no PTY. The surface runs `command` in its own PTY, which for
  /// the app is a tmux client attached to one of sbd's panes.
  final class GhosttySurfaceView: NSView {
    nonisolated(unsafe) static var kept: [GhosttySurfaceView] = []

    private let command: String
    private(set) var surface: ghostty_surface_t?
    private var tracking: NSTrackingArea?

    init(command: String) {
      self.command = command
      super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func from(_ userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
      userdata.map { Unmanaged<GhosttySurfaceView>.fromOpaque($0).takeUnretainedValue() }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Surface lifetime

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil, surface == nil else { return }
      MainActor.assumeIsolated { createSurface() }
    }

    @MainActor private func createSurface() {
      guard let app = GhosttyRuntime.shared.app else { return }
      var config = ghostty_surface_config_new()
      config.userdata = Unmanaged.passUnretained(self).toOpaque()
      config.platform_tag = GHOSTTY_PLATFORM_MACOS
      config.platform = ghostty_platform_u(
        macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
      config.scale_factor = Double(window?.backingScaleFactor ?? 2)
      // TMUX in the app's environment would make the tmux client refuse to nest.
      let line = "/usr/bin/env -u TMUX \(command)"
      surface = line.withCString { cCommand in
        config.command = cCommand
        return ghostty_surface_new(app, &config)
      }
      guard let surface else {
        // With every display asleep, Ghostty can't make its display link and the call fails.
        GhosttyRuntime.log("ghostty_surface_new failed. Trying again when a display wakes.")
        waitForDisplay()
        return
      }
      if let id = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
        ghostty_surface_set_display_id(surface, id)
      }
      ghostty_surface_set_color_scheme(
        surface,
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
      pushSize()
      if window?.firstResponder === window || window?.firstResponder == nil { window?.makeFirstResponder(self) }
    }

    private var wakeObserver: NSObjectProtocol?

    @MainActor private func waitForDisplay() {
      guard wakeObserver == nil else { return }
      wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.surface == nil, self.window != nil else { return }
          self.createSurface()
          if self.surface != nil, let token = self.wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            self.wakeObserver = nil
          }
        }
      }
    }

    /// Frees the surface, which ends the PTY and the tmux client in it. The tmux pane keeps running in sbd.
    func close() {
      if let token = wakeObserver {
        NSWorkspace.shared.notificationCenter.removeObserver(token)
        wakeObserver = nil
      }
      guard let surface else { return }
      self.surface = nil
      ghostty_surface_free(surface)
    }

    deinit { close() }

    private func pushSize() {
      guard let surface else { return }
      let scale = window?.backingScaleFactor ?? 2
      ghostty_surface_set_content_scale(surface, scale, scale)
      let px = convertToBacking(bounds.size)
      ghostty_surface_set_size(surface, UInt32(max(px.width, 1)), UInt32(max(px.height, 1)))
    }

    override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      pushSize()
    }

    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      pushSize()
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let tracking { removeTrackingArea(tracking) }
      let area = NSTrackingArea(
        rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
      addTrackingArea(area)
      tracking = area
    }

    override func becomeFirstResponder() -> Bool {
      if let surface { ghostty_surface_set_focus(surface, true) }
      return true
    }

    override func resignFirstResponder() -> Bool {
      if let surface { ghostty_surface_set_focus(surface, false) }
      return true
    }

    // MARK: Keyboard

    private static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
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

    /// The text a key event types, with control characters and function-key
    /// codes left out, because Ghostty encodes those from the key itself.
    private static func text(of event: NSEvent, with flags: NSEvent.ModifierFlags) -> String? {
      guard let chars = event.characters(byApplyingModifiers: flags), let scalar = chars.unicodeScalars.first else {
        return nil
      }
      if chars.unicodeScalars.count == 1 {
        if scalar.value < 0x20 { return event.characters(byApplyingModifiers: flags.subtracting(.control)) }
        if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
      }
      return chars
    }

    private func send(_ action: ghostty_input_action_e, _ event: NSEvent) {
      guard let surface else { return }
      // The config's macos-option-as-alt decides which modifiers change the typed character.
      let translated = ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags))
      var flags = event.modifierFlags
      for (flag, bit) in [
        (NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL), (.option, GHOSTTY_MODS_ALT),
        (.command, GHOSTTY_MODS_SUPER),
      ] {
        if translated.rawValue & bit.rawValue != 0 { flags.insert(flag) } else { flags.remove(flag) }
      }
      var key = ghostty_input_key_s()
      key.action = action
      key.keycode = UInt32(event.keyCode)
      key.mods = Self.mods(event.modifierFlags)
      key.consumed_mods = Self.mods(flags.subtracting([.control, .command]))
      key.composing = false
      key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
      if action != GHOSTTY_ACTION_RELEASE, let text = Self.text(of: event, with: flags) {
        text.withCString {
          key.text = $0
          _ = ghostty_surface_key(surface, key)
        }
      } else {
        _ = ghostty_surface_key(surface, key)
      }
    }

    override func keyDown(with event: NSEvent) {
      send(event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS, event)
    }

    override func keyUp(with event: NSEvent) { send(GHOSTTY_ACTION_RELEASE, event) }

    @objc func paste(_ sender: Any?) { binding("paste_from_clipboard") }
    @objc func copy(_ sender: Any?) { binding("copy_to_clipboard") }
    @objc override func selectAll(_ sender: Any?) { binding("select_all") }

    private func binding(_ action: String) {
      guard let surface else { return }
      _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: Mouse

    private func position(_ event: NSEvent) {
      guard let surface else { return }
      let point = convert(event.locationInWindow, from: nil)
      ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, Self.mods(event.modifierFlags))
    }

    private func button(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent)
    {
      guard let surface else { return }
      position(event)
      _ = ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }
    override func mouseUp(with event: NSEvent) { button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event) }
    override func rightMouseDown(with event: NSEvent) { button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) }
    override func rightMouseUp(with event: NSEvent) { button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) }
    override func mouseMoved(with event: NSEvent) { position(event) }
    override func mouseDragged(with event: NSEvent) { position(event) }
    override func rightMouseDragged(with event: NSEvent) { position(event) }

    override func scrollWheel(with event: NSEvent) {
      guard let surface else { return }
      var x = event.scrollingDeltaX
      var y = event.scrollingDeltaY
      let precise = event.hasPreciseScrollingDeltas
      if precise {
        x *= 2
        y *= 2
      }
      let momentum: Int32 =
        switch event.momentumPhase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
      ghostty_surface_mouse_scroll(surface, x, y, (precise ? 1 : 0) | (momentum << 1))
    }
  }

  struct GhosttyPane: NSViewRepresentable {
    /// The tmux attach command as one line for a POSIX shell.
    let command: String

    func makeNSView(context: Context) -> GhosttySurfaceView { GhosttySurfaceView(command: command) }
    func updateNSView(_ view: GhosttySurfaceView, context: Context) {}
    static func dismantleNSView(_ view: GhosttySurfaceView, coordinator: ()) {
      // SB_GHOSTTY_KEEP=1 keeps every surface alive after its view leaves the window, to measure what hidden surfaces cost.
      if getenv("SB_GHOSTTY_KEEP") != nil {
        GhosttySurfaceView.kept.append(view)
        if let surface = view.surface { ghostty_surface_set_occlusion(surface, false) }
        return
      }
      view.close()
    }
  }
#endif
