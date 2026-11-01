#if SB_GHOSTTY
  import AppKit
  import IOSurface

  /// Scripted checks of the surface lifetime in the running app, for a Mac with
  /// no one at the keyboard. SB_LIFETIME_TEST=<scenario> selects the first
  /// session, then logs "lifetime: <step>" lines that carry the number of live
  /// surfaces and how many of them have drawn. A script outside the app
  /// samples the child processes and the footprint between the steps.
  ///
  /// - `close`: closes the window, then shows it again, as the menu bar's "Open Switchboard" does.
  /// - `hide`: hides the app, then unhides it.
  /// - `minimize`: minimizes the window, then restores it.
  /// - `select-while-closed`: selects another session while the window is closed, then shows the window.
  /// - `reparent`: takes the surface views out of the window and puts them back.
  /// - `watch`: reports every 3 s for two minutes, while a script sleeps and wakes the displays.
  /// - `wake`: posts the screens-did-wake notification with surfaces open.
  @MainActor
  enum LifetimeSelfTest {
    private static var started = false

    static func start(_ model: BoardModel) {
      guard let scenario = ProcessInfo.processInfo.environment["SB_LIFETIME_TEST"], !started else { return }
      started = true
      Task { @MainActor in
        while model.sessions.isEmpty { try? await Task.sleep(nanoseconds: 200_000_000) }
        model.selection = model.sessions.first?.id
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        report("start")
        guard let window = NSApp.windows.first(where: { $0.title == "Switchboard" }) else {
          return log("no window")
        }
        switch scenario {
        case "close":
          window.close()
          await settle("closed")
          window.makeKeyAndOrderFront(nil)
          await settle("shown again")
        case "hide":
          NSApp.hide(nil)
          await settle("hidden")
          NSApp.unhide(nil)
          await settle("unhidden")
        case "minimize":
          window.miniaturize(nil)
          await settle("minimized")
          window.deminiaturize(nil)
          await settle("restored")
        case "select-while-closed":
          // The menu bar sets the selection before it shows the window.
          window.close()
          await settle("closed")
          model.selection = model.sessions.dropFirst().first?.id
          await settle("selected another session while closed")
          window.makeKeyAndOrderFront(nil)
          await settle("shown again")
        case "reparent":
          // What a rebuilt HSplitView does to its panes: the views leave the window and come back.
          let views = surfaceViews()
          let parents = views.map { $0.superview }
          for view in views { view.removeFromSuperview() }
          await settle("views removed")
          for (view, parent) in zip(views, parents) { parent?.addSubview(view) }
          await settle("views added back")
        case "watch":
          for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            report("watch")
          }
        case "wake":
          NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
          await settle("wake posted")
        default:
          log("unknown scenario \(scenario)")
        }
        log("done")
      }
    }

    private static func settle(_ step: String) async {
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      report(step)
      try? await Task.sleep(nanoseconds: 6_000_000_000)
    }

    private static func surfaceViews() -> [GhosttySurfaceView] {
      var found: [GhosttySurfaceView] = []
      func walk(_ view: NSView) {
        if let surface = view as? GhosttySurfaceView { found.append(surface) }
        view.subviews.forEach(walk)
      }
      for window in NSApp.windows { window.contentView.map(walk) }
      return found
    }

    private static func report(_ step: String) {
      let views = surfaceViews()
      let live = views.filter { $0.surface != nil }.count
      let drawn = views.filter { $0.surface != nil && $0.layer?.contents != nil }.count
      let sums = views.compactMap { checksum($0) }.map { String($0, radix: 16) }.joined(separator: ",")
      let w = NSApp.windows.first(where: { $0.title == "Switchboard" })
      log(
        "\(step): window visible \(w?.isVisible ?? false) occlusionVisible \(w?.occlusionState.contains(.visible) ?? false) views \(views.count) live \(live) drawn \(drawn) pixels \(sums)"
      )
    }

    /// A hash of the pixels the surface last presented, to see whether it still draws.
    private static func checksum(_ view: GhosttySurfaceView) -> UInt64? {
      guard let contents = view.layer?.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else {
        return nil
      }
      let surface = contents as! IOSurfaceRef
      IOSurfaceLock(surface, .readOnly, nil)
      defer { IOSurfaceUnlock(surface, .readOnly, nil) }
      let bytes = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
      var hash: UInt64 = 1_469_598_103_934_665_603
      for i in stride(from: 0, to: IOSurfaceGetAllocSize(surface), by: 61) {
        hash = (hash ^ UInt64(bytes[i])) &* 1_099_511_628_211
      }
      return hash
    }

    private static func log(_ text: String) { FileHandle.standardError.write(Data("lifetime: \(text)\n".utf8)) }
  }
#endif
