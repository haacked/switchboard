import AppKit

/// A launch that sets one of `hooks` runs a script with no one watching, so it stays out of the user's way. The
/// app has no Dock icon and never makes itself the active app. Its windows and sheets are fully transparent and
/// let clicks through to the windows below them. AppKit still lays them out at their usual frames, so the self
/// tests and snapshots see the same views. SB_TEST_VISIBLE=1 makes such a launch behave like a normal one.
@MainActor
enum BackgroundLaunch {
  /// A new hook that drives the app with no one watching belongs here. A hook that only chooses what to show, such
  /// as SB_SELECT, does not.
  static let hooks = ["SB_SNAPSHOT", "SB_TERMINAL_TEST", "SB_DRAFT_TEST", "SB_QUIT_FILE"]

  static func applies(to env: [String: String]) -> Bool {
    env["SB_TEST_VISIBLE"] != "1" && hooks.contains { env[$0] != nil }
  }

  /// Runs from `applicationDidFinishLaunching`. SwiftUI has ordered in the main window by then. The screen has
  /// not drawn it yet.
  static func start() {
    NSApp.setActivationPolicy(.accessory)
    NSApp.windows.forEach(hide)
    hideWindowsAsTheyUpdate()
  }

  /// A sheet opens after launch, so every window update checks for new windows.
  @discardableResult
  static func hideWindowsAsTheyUpdate(_ center: NotificationCenter = .default) -> NSObjectProtocol {
    center.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
      MainActor.assumeIsolated {
        if let window = note.object as? NSWindow { hide(window) }
      }
    }
  }

  /// Leaves the menu bar item alone, because its window sits above the normal level.
  static func hide(_ window: NSWindow) {
    guard window.level == .normal, window.alphaValue != 0 else { return }
    window.alphaValue = 0
    window.ignoresMouseEvents = true
  }
}
