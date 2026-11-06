import AppKit
import Foundation

/// Hooks for scripted checks of the GUI. SB_SELECT selects a session when the
/// app starts, SB_INBOX focuses a session's item in the Inbox, SB_BOARD_CLICK starts on the Board and clicks that session's card after 2 seconds, SB_JUMP then runs Next Needing You (⌘J) after 3, SB_SHEET=import opens the import sheet, and SB_QUIT_FILE=<path> quits the app (⌘Q) once that file exists. SB_SNAPSHOT names a
/// PNG file that the app draws its main window, or the window's open sheet,
/// into after SB_SNAPSHOT_DELAY seconds (default 3). The app draws the
/// window itself, so this needs no screen recording permission. The drawing
/// leaves out the window's background, so the snapshot fills it in with the
/// window background color first. A snapshot run uses the light appearance,
/// or the dark one with SB_SNAPSHOT_APPEARANCE=dark. SwiftTerm draws text in
/// layers that the drawing misses, so `sb screen` checks terminals.
@MainActor
enum Snapshot {
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
    if let path = env["SB_QUIT_FILE"] {
      Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
        if FileManager.default.fileExists(atPath: path) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
      }
    }
    TerminalSelfTest.start(model)
    DraftSelfTest.start(model)
    ShellSelfTest.start(model)
    guard let path = env["SB_SNAPSHOT"] else { return }
    NSApp.appearance = NSAppearance(named: env["SB_SNAPSHOT_APPEARANCE"] == "dark" ? .darkAqua : .aqua)
    let delay = Double(env["SB_SNAPSHOT_DELAY"] ?? "3") ?? 3
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      write(to: path)
      if env["SB_SNAPSHOT_EXIT"] != nil { NSApp.terminate(nil) }
    }
  }

  static func write(to path: String) {
    let window = NSApp.windows.first { $0.isVisible && $0.title == "Switchboard" }
    guard let view = (window?.attachedSheet ?? window)?.contentView,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else {
      FileHandle.standardError.write(Data("snapshot: no window to draw\n".utf8))
      return
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    var background = NSColor.white.cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.cgColor }
    guard let image = rep.cgImage,
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.setFillColor(background)
    context.fill(bounds)
    context.draw(image, in: bounds)
    guard let composed = context.makeImage() else { return }
    let out = NSBitmapImageRep(cgImage: composed)
    do {
      try out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    } catch {
      FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
    }
  }
}
