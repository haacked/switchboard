import AppKit
import Foundation

/// Hooks for scripted checks of the GUI. SB_SELECT selects a session when the
/// app starts. SB_SNAPSHOT names a PNG file that the app draws its main
/// window into after SB_SNAPSHOT_DELAY seconds (default 3). The app draws the
/// window itself, so this needs no screen recording permission. The drawing
/// leaves out the window's background, so a snapshot run uses the light
/// appearance, whose text reads on the white that remains. SwiftTerm draws
/// text in layers that the drawing misses, so `sb screen` checks terminals.
@MainActor
enum Snapshot {
  static func start(_ model: BoardModel) {
    let env = ProcessInfo.processInfo.environment
    if let id = env["SB_SELECT"] { model.selection = id }
    guard let path = env["SB_SNAPSHOT"] else { return }
    NSApp.appearance = NSAppearance(named: .aqua)
    let delay = Double(env["SB_SNAPSHOT_DELAY"] ?? "3") ?? 3
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      write(to: path)
      if env["SB_SNAPSHOT_EXIT"] != nil { NSApp.terminate(nil) }
    }
  }

  static func write(to path: String) {
    guard let view = NSApp.windows.first(where: { $0.isVisible && $0.title == "Switchboard" })?.contentView,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else {
      FileHandle.standardError.write(Data("snapshot: no window to draw\n".utf8))
      return
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    do {
      try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    } catch {
      FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
    }
  }
}
