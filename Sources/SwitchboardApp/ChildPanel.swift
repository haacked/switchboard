import AppKit

/// A borderless panel that shows above a window as its child window. The panel never becomes key, so typing stays in
/// the window.
@MainActor
enum ChildPanel {
  static let gap: CGFloat = 4

  static func make(contentView: NSView) -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.transient, .ignoresCycle]
    panel.contentView = contentView
    return panel
  }

  static func attach(_ panel: NSPanel, to window: NSWindow) {
    guard panel.parent !== window else { return }
    panel.parent?.removeChildWindow(panel)
    window.addChildWindow(panel, ordered: .above)
  }

  static func detach(_ panel: NSPanel) {
    panel.parent?.removeChildWindow(panel)
    panel.orderOut(nil)
  }

  /// The anchor's frame and the visible frame of the window's screen, in screen coordinates. A window off every
  /// screen gets a large rect around the anchor in place of the screen.
  static func frames(of anchor: NSView, in window: NSWindow) -> (anchor: NSRect, screen: NSRect) {
    let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    return (frame, window.screen?.visibleFrame ?? frame.insetBy(dx: -10_000, dy: -10_000))
  }

  /// The bottom edge of a panel `height` tall under `anchor`, or above it when the screen has no room below.
  static func y(height: CGFloat, anchor: NSRect, screen: NSRect) -> CGFloat {
    let below = anchor.minY - gap - height
    return below < screen.minY ? anchor.maxY + gap : below
  }
}
