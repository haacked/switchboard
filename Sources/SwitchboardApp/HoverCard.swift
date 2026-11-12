import AppKit

/// Draws the hover card that `HoverCard` decides to show.
@MainActor
protocol HoverCardPresenter: AnyObject {
  func show(_ id: String, below anchor: NSView)
  func hide()
  /// Measures and places the card again below `anchor`, after its contents changed or its tile was rebuilt.
  func refresh(below anchor: NSView)
}

/// Decides when a session tile's hover card shows. The card opens after the
/// pointer rests on a tile for `delay`. It stays open while the pointer is on
/// the tile or on the card, and closes `grace` after the pointer leaves both.
/// A model update leaves the card open unless the session is no longer shown.
/// A rebuilt tile replaces its anchor view. The new anchor keeps the card.
@MainActor
final class HoverCard {
  typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

  private(set) var shown: String?
  private let presenter: HoverCardPresenter
  private let delay: TimeInterval
  private let grace: TimeInterval
  private let schedule: Schedule
  private let buttonsPressed: () -> Bool

  private var hovered: (id: String, anchor: NSView)?
  /// The anchor that the open card sits below.
  private var anchor: NSView?
  private var onCard = false
  /// A tile whose card a click or key closed. It shows again only after the pointer leaves it.
  private var suppressed: String?
  private var cancelPending: (() -> Void)?

  init(
    presenter: HoverCardPresenter, delay: TimeInterval = 0.5, grace: TimeInterval = 0.25,
    schedule: @escaping Schedule = HoverCard.timer,
    buttonsPressed: @escaping () -> Bool = { NSEvent.pressedMouseButtons != 0 }
  ) {
    self.presenter = presenter
    self.delay = delay
    self.grace = grace
    self.schedule = schedule
    self.buttonsPressed = buttonsPressed
  }

  static func timer(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
    let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
      MainActor.assumeIsolated { action() }
    }
    return { timer.invalidate() }
  }

  func entered(_ id: String, anchor: NSView) {
    hovered = (id, anchor)
    // A tile under the card can report an enter while the pointer is on the card.
    if onCard, shown != nil, shown != id { return }
    if shown == id {
      adopt(anchor)
      cancel()
      return
    }
    // A drag to a group crosses other tiles with the button down.
    guard suppressed != id, !buttonsPressed() else { return }
    after(delay) { [weak self] in self?.open(id, below: anchor) }
  }

  func exited(_ id: String, anchor: NSView) {
    guard hovered?.anchor === anchor else { return }
    hovered = nil
    if suppressed == id { suppressed = nil }
    if shown == nil { cancel() } else if !onCard { closeAfterGrace() }
  }

  /// A tile's anchor joined a window. SwiftUI replaces a tile's anchor when it
  /// rebuilds the tile. The new anchor gets no enter event while the pointer rests on it.
  func appeared(_ id: String, anchor: NSView, pointerInside: Bool) {
    if shown == id, self.anchor?.window == nil {
      adopt(anchor)
      if pointerInside { hovered = (id, anchor) }
      if pointerInside || onCard { cancel() }
      return
    }
    if pointerInside { entered(id, anchor: anchor) }
  }

  func disappeared(anchor: NSView) {
    let wasHovered = hovered?.anchor === anchor
    if wasHovered { hovered = nil }
    guard wasHovered || anchor === self.anchor else { return }
    // A pending open targets the hovered anchor, which can no longer show a card.
    if shown == nil { cancel() } else if !onCard { closeAfterGrace() }
  }

  func enteredCard() {
    onCard = true
    if shown != nil { cancel() }
  }

  func exitedCard() {
    onCard = false
    guard shown != nil else { return }
    if let tile = hovered {
      if tile.id != shown, suppressed != tile.id {
        after(delay) { [weak self] in self?.open(tile.id, below: tile.anchor) }
      }
    } else {
      closeAfterGrace()
    }
  }

  /// A mouse down, a scroll, or a key closes the card at once, as it closes a native tooltip.
  func interrupt() {
    suppressed = hovered?.id
    cancel()
    close()
  }

  func sessionsChanged(shown ids: Set<String>) {
    guard let shown, let anchor else { return }
    if ids.contains(shown) { presenter.refresh(below: anchor) } else { close() }
  }

  /// Shows the card for `id` without a pointer, for a snapshot.
  func pin(_ id: String, below anchor: NSView) { open(id, below: anchor) }

  private func open(_ id: String, below anchor: NSView) {
    cancel()
    shown = id
    self.anchor = anchor
    presenter.show(id, below: anchor)
  }

  private func adopt(_ anchor: NSView) {
    guard anchor !== self.anchor else { return }
    self.anchor = anchor
    presenter.refresh(below: anchor)
  }

  private func close() {
    guard shown != nil else { return }
    shown = nil
    anchor = nil
    onCard = false
    presenter.hide()
  }

  private func closeAfterGrace() {
    after(grace) { [weak self] in self?.close() }
  }

  private func after(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) {
    cancel()
    cancelPending = schedule(interval) { [weak self] in
      self?.cancelPending = nil
      action()
    }
  }

  private func cancel() {
    cancelPending?()
    cancelPending = nil
  }
}
