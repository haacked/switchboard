/// When a terminal view holds a libghostty surface. A view holds one only
/// while it is in a window that is open, so a session that is not on screen
/// keeps no renderer and no PTY. Each event returns what the view must do.
struct SurfaceLifetime {
  enum Action: Equatable {
    case create
    case free
  }

  private var inWindow = false
  private var windowIsClosed = false
  private var hasSurface = false

  mutating func enteredWindow() -> Action? {
    inWindow = true
    windowIsClosed = false
    return hasSurface ? nil : .create
  }

  mutating func leftWindow() -> Action? {
    inWindow = false
    return hasSurface ? .free : nil
  }

  mutating func windowClosed() -> Action? {
    windowIsClosed = true
    return hasSurface ? .free : nil
  }

  /// The window became visible, which includes a closed window that opens again.
  mutating func windowShown() -> Action? {
    guard inWindow, windowIsClosed else { return nil }
    windowIsClosed = false
    return hasSurface ? nil : .create
  }

  /// A display woke, which can make a create succeed that failed while every display slept.
  func displayWoke() -> Action? {
    inWindow && !windowIsClosed && !hasSurface ? .create : nil
  }

  mutating func surfaceCreated() { hasSurface = true }
  mutating func surfaceFreed() { hasSurface = false }
}
