import AppKit

/// A launch that sets SB_SNAPSHOT, SB_TERMINAL_TEST, SB_DRAFT_TEST, or SB_QUIT_FILE runs a script with no one
/// watching, so it stays out of the user's way. The app has no Dock icon and never makes itself the active app.
/// Its windows and sheets are fully transparent and let clicks through to the windows below them. AppKit still
/// lays them out at their usual frames, so the self tests and snapshots see the same views. SB_TEST_VISIBLE=1
/// makes such a launch behave like a normal one.
@MainActor
enum BackgroundLaunch {
  static let hooks = ["SB_SNAPSHOT", "SB_TERMINAL_TEST", "SB_DRAFT_TEST", "SB_QUIT_FILE"]

  private static var observer: NSObjectProtocol?

  static func applies(to env: [String: String]) -> Bool {
    env["SB_TEST_VISIBLE"] != "1" && hooks.contains { env[$0] != nil }
  }

  /// Runs from `applicationDidFinishLaunching`. SwiftUI has ordered in the main window by then, but the screen
  /// has not drawn it yet. A sheet opens later, so every window update checks for new windows.
  static func start() {
    NSApp.setActivationPolicy(.accessory)
    NSApp.windows.forEach(hide)
    observer = NotificationCenter.default.addObserver(
      forName: NSWindow.didUpdateNotification, object: nil, queue: .main
    ) { note in
      MainActor.assumeIsolated { (note.object as? NSWindow).map(hide) }
    }
  }

  /// Leaves the menu bar item alone, because its window sits above the normal level.
  static func hide(_ window: NSWindow) {
    guard window.level == .normal, window.alphaValue != 0 else { return }
    window.alphaValue = 0
    window.ignoresMouseEvents = true
  }
}
