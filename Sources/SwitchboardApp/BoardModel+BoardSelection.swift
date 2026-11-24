import AppKit
import SwitchboardCore

/// What a click on a Board card does.
enum BoardClick: Equatable {
  case select, toggle, extend, open

  /// A second click of a double click opens, and so does an activation that is not a mouse click, such as
  /// VoiceOver's press. ⌘ wins over ⇧ when both are held.
  static func from(clickCount: Int, modifiers: NSEvent.ModifierFlags, isMouse: Bool) -> BoardClick {
    guard isMouse, clickCount < 2 else { return .open }
    if modifiers.contains(.command) { return .toggle }
    if modifiers.contains(.shift) { return .extend }
    return .select
  }

  /// The click that the event being handled makes.
  static var current: BoardClick {
    guard let event = NSApp.currentEvent else { return .open }
    let isMouse = [.leftMouseDown, .leftMouseUp].contains(event.type)
    return from(clickCount: isMouse ? event.clickCount : 0, modifiers: event.modifierFlags, isMouse: isMouse)
  }
}

/// A drag of Board cards carries their ids as one string, one id per line.
enum BoardDrag {
  static func payload(_ ids: [String]) -> String { ids.joined(separator: "\n") }

  static func ids(from payload: String) -> [String] {
    payload.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }
}

/// The geometry of the Board's selection rectangle. Frames and points are in the Board content's coordinate
/// space, which scrolling does not change.
enum BoardRect {
  /// The rectangle with corners `start` and `end`, whichever way the drag went.
  static func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
    CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
  }

  /// The ids whose card frame overlaps `rect`. A frame that only touches its edge does not count.
  static func hits(_ rect: CGRect, frames: [String: CGRect]) -> Set<String> {
    Set(frames.filter { $0.value.intersects(rect) }.keys)
  }

  /// Whether a drag or a click at `point` acts on empty Board space. A start on a card or in a `blocked` rect,
  /// such as the pinned header or a lane's header, belongs to the view there.
  static func startsSelection(at point: CGPoint, frames: [String: CGRect], blocked: [CGRect]) -> Bool {
    !blocked.contains { $0.contains(point) } && !frames.values.contains { $0.contains(point) }
  }

  /// How far to scroll while a rectangle drag's pointer is within 24 points of an edge of the visible area,
  /// or past it. The pointer and `visible` are in the scroll view's coordinates, with y increasing
  /// downward. The top zone starts below the pinned header, which is `headerHeight` tall.
  static func autoscrollDelta(pointer: CGPoint, visible: CGSize, headerHeight: CGFloat) -> CGVector {
    let zone: CGFloat = 24
    let speed: CGFloat = 0.5
    func step(_ position: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
      if position < low + zone { return -(low + zone - position) * speed }
      if position > high - zone { return (position - (high - zone)) * speed }
      return 0
    }
    return CGVector(
      dx: step(pointer.x, low: 0, high: visible.width),
      dy: step(pointer.y, low: headerHeight, high: visible.height))
  }
}

extension BoardModel {
  /// Selects, extends, or opens from a click on a Board card. A click that does not open moves the focus ring
  /// to the card, so Return opens it.
  func clickBoardCard(_ id: String, _ click: BoardClick) {
    switch click {
    case .open:
      openFromBoard(id)
      return
    case .select:
      setMultiSelection([id])
      boardSelectionAnchor = id
    case .toggle:
      toggleBoardCard(id)
    case .extend:
      guard let range = boardRange(from: boardSelectionAnchor, to: id) else {
        clickBoardCard(id, .select)
        return
      }
      setMultiSelection(multiSelection.union(range))
    }
    boardFocus = id
  }

  /// The ids that a drag or the Move menu of card `id` acts on: the selected lane cards in reading order when
  /// the selection holds the card, else the card alone. Done cards have no lane, so they never move.
  func boardActionIDs(for id: String) -> [String] {
    guard multiSelection.contains(id) else { return [id] }
    return boardGrid.readingOrder.filter(multiSelection.contains)
  }

  /// Moves the cards that a drop on a lane delivers, as `BoardDrag` payloads, to `group`.
  @discardableResult
  func dropBoardCards(_ payloads: [String], on group: String?) -> Bool {
    moveToGroup(payloads.flatMap(BoardDrag.ids(from:)), group)
  }

  func clearBoardSelection() { setMultiSelection([]) }

  /// Adds the focused card to the Board selection, or removes it, as ⌘-click does.
  func toggleFocusedBoardCard() {
    if let id = currentBoardCard { toggleBoardCard(id) }
  }

  /// Moves the focus ring and adds every card from the anchor to the new focus, as ⇧-click does. Without an
  /// anchor, the card the ring left becomes it.
  func extendBoardSelection(_ direction: BoardDirection) {
    let from = currentBoardCard
    moveBoardFocus(direction)
    guard let from, let to = currentBoardCard else { return }
    if boardSelectionAnchor.map(boardGrid.contains) != true { boardSelectionAnchor = from }
    setMultiSelection(multiSelection.union(boardRange(from: boardSelectionAnchor, to: to) ?? [to]))
  }

  /// The Board selection a rectangle makes: the cards it touches, added to `base` for a ⌘-drag. The first hit
  /// in reading order becomes the anchor.
  func selectBoardRect(_ hits: Set<String>, adding base: Set<String> = []) {
    setMultiSelection(base.union(hits))
    if let first = boardGrid.readingOrder.first(where: hits.contains) ?? hits.min() { boardSelectionAnchor = first }
  }

  /// The cards from `anchor` to `id` in reading order, both included, or nil when either is not in it.
  private func boardRange(from anchor: String?, to id: String) -> [String]? {
    let order = boardGrid.readingOrder
    guard let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) else { return nil }
    return Array(order[min(a, b)...max(a, b)])
  }

  private func toggleBoardCard(_ id: String) {
    var ids = multiSelection
    if ids.remove(id) == nil { ids.insert(id) }
    setMultiSelection(ids)
    boardSelectionAnchor = id
  }
}
