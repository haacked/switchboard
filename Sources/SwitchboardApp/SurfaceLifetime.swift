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

  private var createIfMissing: Action? { hasSurface ? nil : .create }
  private var freeIfHeld: Action? { hasSurface ? .free : nil }

  /// A view that enters a window that isn't visible creates no surface until `windowShown()`. A view that already holds a surface keeps it.
  mutating func enteredWindow(windowIsVisible: Bool) -> Action? {
    inWindow = true
    windowIsClosed = !windowIsVisible
    return windowIsVisible ? createIfMissing : nil
  }

  mutating func leftWindow() -> Action? {
    inWindow = false
    return freeIfHeld
  }

  mutating func windowClosed() -> Action? {
    windowIsClosed = true
    return freeIfHeld
  }

  /// The window became visible, which includes a closed window that opens again.
  mutating func windowShown() -> Action? {
    guard inWindow, windowIsClosed else { return nil }
    windowIsClosed = false
    return createIfMissing
  }

  /// A display woke, which can make a create succeed that failed while every display slept.
  func displayWoke() -> Action? {
    inWindow && !windowIsClosed && !hasSurface ? .create : nil
  }

  mutating func surfaceCreated() { hasSurface = true }
  mutating func surfaceFreed() { hasSurface = false }
}
