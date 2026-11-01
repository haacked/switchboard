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
    /// TERM=xterm-256color. An app bundle carries the folder; a development build finds it in .build/ghostty.
    private static func pointToResources() {
      if getenv("GHOSTTY_RESOURCES_DIR") != nil { return }
      if let url = GhosttyResources.locate(
        resourceURL: Bundle.main.resourceURL, executableURL: Bundle.main.executableURL,
        inBundle: Bundle.main.bundleIdentifier != nil)
      {
        setenv("GHOSTTY_RESOURCES_DIR", url.path, 1)
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
    /// Text the input method is composing. See GhosttySurfaceView+Input.swift.
    var marked = MarkedText()
    /// The strings the input context inserted during the current keyDown, or nil outside a keyDown.
    var keyTexts: [String]?

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

    /// SB_GHOSTTY_KEEP=1 keeps every surface alive after its view leaves the window, to measure what hidden surfaces cost.
    private static let keepsHiddenSurfaces = getenv("SB_GHOSTTY_KEEP") != nil

    /// `ghostty_surface_free` takes about 16 ms, which would stall the main thread on every session switch.
    private static let freeQueue = DispatchQueue(label: "switchboard.ghostty.free")

    private var lifetime = SurfaceLifetime()
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var visibility: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopObserving()
      guard let window else { return perform(lifetime.leftWindow()) }
      let notifications = NotificationCenter.default
      observers.append(
        (notifications, observe(notifications, NSWindow.willCloseNotification, window) { $0.lifetime.windowClosed() }))
      visibility = window.observe(\.isVisible) { [weak self] window, _ in
        guard window.isVisible else { return }
        MainActor.assumeIsolated { if let self { self.perform(self.lifetime.windowShown()) } }
      }
      // A create fails while every display sleeps, so it is tried again when one wakes.
      let workspace = NSWorkspace.shared.notificationCenter
      observers.append(
        (workspace, observe(workspace, NSWorkspace.screensDidWakeNotification, nil) { $0.lifetime.displayWoke() }))
      perform(lifetime.enteredWindow())
    }

    private func observe(
      _ center: NotificationCenter, _ name: Notification.Name, _ object: AnyObject?,
      _ event: @escaping (GhosttySurfaceView) -> SurfaceLifetime.Action?
    ) -> NSObjectProtocol {
      center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { if let self { self.perform(event(self)) } }
      }
    }

    private func stopObserving() {
      for (center, token) in observers { center.removeObserver(token) }
      observers = []
      visibility = nil
    }

    @MainActor private func perform(_ action: SurfaceLifetime.Action?) {
      switch action {
      case .create: createSurface()
      case .free: if !Self.keepsHiddenSurfaces { freeSurface() }
      case nil: break
      }
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
        GhosttyRuntime.log("ghostty_surface_new failed. Trying again when a display wakes.")
        return
      }
      lifetime.surfaceCreated()
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

    /// Ends the PTY and the tmux client in it. The tmux pane keeps running in sbd. The view stays alive until
    /// the free finishes, because the surface holds the view's address.
    private func freeSurface() {
      guard let surface else { return }
      self.surface = nil
      lifetime.surfaceFreed()
      Self.freeQueue.async {
        ghostty_surface_free(surface)
        withExtendedLifetime(self) {}
      }
    }

    /// Called when SwiftUI removes the view.
    func close() {
      stopObserving()
      if !Self.keepsHiddenSurfaces { freeSurface() }
    }

    deinit {
      stopObserving()
      // Only reached with a surface when SB_GHOSTTY_KEEP is off and nothing freed it, which close() prevents.
      if let surface { ghostty_surface_free(surface) }
    }

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
      discardComposition()
      if let surface { ghostty_surface_set_focus(surface, false) }
      return true
    }

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
      if getenv("SB_GHOSTTY_KEEP") != nil {
        GhosttySurfaceView.kept.append(view)
        if let surface = view.surface { ghostty_surface_set_occlusion(surface, false) }
        return
      }
      view.close()
    }
  }
#endif
