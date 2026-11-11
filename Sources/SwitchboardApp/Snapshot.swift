import AppKit
import Foundation
import SwitchboardCore

/// Hooks for scripted checks of the GUI. SB_SELECT selects a session when the
/// app starts, SB_INBOX focuses a session's item in the Inbox, SB_BOARD_CLICK starts on the Board and clicks that session's card after 2 seconds, SB_JUMP then runs Next Needing You (⌘J) after 3, SB_SHEET=import opens the import sheet, SB_DETAILS opens each card's Details, SB_ACCOUNTS=open opens the account menu once the accounts and their usage are read, SB_ACCOUNTS_CHOOSE=<name> then chooses that account a second later, SB_ACCOUNTS_MOVE=1 instead presses the menu's Move button, SB_ACCOUNTS_CONFIRM=new-only or move then answers the switch's dialog 2 seconds after that, SB_ORG_FILTER=<org,org> starts the app with that org filter, where `(local)` names the sessions with no GitHub remote, SB_ORGS=open opens the org filter's menu once sbd lists the sessions, and SB_QUIT_FILE=<path> quits the app (⌘Q) once that file exists. SB_SNAPSHOT names a
/// PNG file that the app draws its windows into after SB_SNAPSHOT_DELAY
/// seconds (default 3): the main window with its toolbar, and any sheet or
/// popover in front of it. The app draws the windows itself, so this needs no
/// screen recording permission. The drawing leaves out the windows'
/// translucent backgrounds, so each window gets a plain background color
/// first. SB_SNAPSHOT_APPEARANCE=dark draws the dark appearance, and the default is
/// light. SB_SNAPSHOT_SIZE=<width>x<height> sets the window's content size in
/// points 1 s before the drawing, so a narrow layout can be drawn, and puts
/// the window's frame back after it. SwiftTerm draws text in layers that the
/// drawing misses, so `sb screen` checks terminals.
@MainActor
enum Snapshot {
  static let opensDetails = ProcessInfo.processInfo.environment["SB_DETAILS"] != nil
  static let orgFilter = OrgFilter(list: ProcessInfo.processInfo.environment["SB_ORG_FILTER"] ?? "")

  static func start(_ model: BoardModel) {
    let env = ProcessInfo.processInfo.environment
    if let id = env["SB_SELECT"] { model.selection = id }
    if let id = env["SB_INBOX"] { model.inboxFocus = id }
    if let id = env["SB_BOARD_CLICK"] {
      model.show(.board)
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openFromBoard(id) }
      if env["SB_JUMP"] != nil {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { model.selectNextNeedingYou() }
      }
    }
    if env["SB_SHEET"] == "import" { model.showingImport = true }
    if env["SB_ACCOUNTS"] == "open" {
      openAccounts(
        model, choose: env["SB_ACCOUNTS_CHOOSE"], move: env["SB_ACCOUNTS_MOVE"] != nil,
        confirm: env["SB_ACCOUNTS_CONFIRM"])
    }
    if env["SB_ORGS"] == "open" {
      Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
        MainActor.assumeIsolated {
          guard !model.allSessions.isEmpty else { return }
          timer.invalidate()
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.showingOrgFilter = true }
        }
      }
    }
    if let path = env["SB_QUIT_FILE"] {
      Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
        if FileManager.default.fileExists(atPath: path) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
      }
    }
    TerminalSelfTest.start(model)
    DraftSelfTest.start(model)
    ShellSelfTest.start(model)
    DropSelfTest.start(model)
    guard let path = env["SB_SNAPSHOT"] else { return }
    NSApp.appearance = NSAppearance(named: env["SB_SNAPSHOT_APPEARANCE"] == "dark" ? .darkAqua : .aqua)
    let delay = Double(env["SB_SNAPSHOT_DELAY"] ?? "3") ?? 3
    let size = env["SB_SNAPSHOT_SIZE"].flatMap(contentSize)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      let window = size == nil ? nil : NSApp.switchboardWindow
      let frame = window?.frame
      if let size, let window {
        window.setContentSize(size)
        window.contentView?.layoutSubtreeIfNeeded()
      }
      // The split views fit their panes to the new size only on a later turn of the run loop.
      DispatchQueue.main.asyncAfter(deadline: .now() + (size == nil ? 0 : 1)) {
        write(to: path)
        // AppKit saves the main window's frame on every change. Restoring it keeps the next launch at the user's last size.
        if let window, let frame { window.setFrame(frame, display: false) }
        if env["SB_SNAPSHOT_EXIT"] != nil { NSApp.terminate(nil) }
      }
    }
  }

  /// The account menu exists only once the accounts are read, so the hook
  /// waits for them before it opens the menu.
  private static func openAccounts(_ model: BoardModel, choose name: String?, move: Bool, confirm answer: String?) {
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
      MainActor.assumeIsolated {
        guard !model.accounts.isEmpty, !model.usage.isEmpty else { return }
        timer.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.showingAccounts = true }
        let account = model.accounts.first { $0.name == name }
        guard account != nil || move else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          if let account { model.useAccount(account.folder) } else if let plan = model.movable { model.offerMove(plan) }
        }
        guard let answer else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
          if let change = model.switchingAccount { model.confirmAccountSwitch(change, move: answer == "move") }
        }
      }
    }
  }

  /// The size that `<width>x<height>` names, or nil when the text is not one.
  nonisolated static func contentSize(_ text: String) -> NSSize? {
    let parts = text.split(separator: "x", omittingEmptySubsequences: false).map { Double($0) ?? 0 }
    guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { return nil }
    return NSSize(width: parts[0], height: parts[1])
  }

  static func write(to path: String) {
    guard let main = NSApp.switchboardWindow else {
      FileHandle.standardError.write(Data("snapshot: no window to draw\n".utf8))
      return
    }
    // A popover's window is a child window of the window that presents it.
    let popovers = (main.childWindows ?? []).filter(\.isVisible)
    let windows = [main] + [main.attachedSheet].compactMap { $0 } + popovers
    let bounds = windows.reduce(main.frame) { $0.union($1.frame) }
    let scale = main.backingScaleFactor
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { return }
    rep.size = bounds.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for window in windows {
      // The theme frame holds the toolbar as well as the content. A popover's
      // frame draws its shadow as colored noise, so only its content draws.
      let popover = popovers.contains(window)
      guard let content = window.contentView else { continue }
      let view = popover ? content : content.superview ?? content
      guard let layer = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
      view.cacheDisplay(in: view.bounds, to: layer)
      let rect = window.convertToScreen(view.convert(view.bounds, to: nil)).offsetBy(dx: -bounds.minX, dy: -bounds.minY)
      window.effectiveAppearance.performAsCurrentDrawingAppearance {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        if popover {
          NSColor.separatorColor.setStroke()
          NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10).stroke()
        }
      }
      layer.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    NSGraphicsContext.restoreGraphicsState()
    do {
      try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    } catch {
      FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
    }
  }
}
