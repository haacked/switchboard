import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The Board with reading order a, b, c, d, w. Lane 1 holds a in its first column and b over c in its second.
/// Lane 2 holds d over w in its second column. `w` works with no Inbox item. `z` is Done, so it shows in the
/// Done footer and not in the grid.
@MainActor
private func board() -> BoardModel {
  var w = needsItem("w", state: .working)
  w.triage = nil
  let model = appliedModel(["a", "b", "c", "d"].map { needsItem($0) } + [w, needsItem("z", state: .done)])
  model.show(.board)
  model.boardGrid = BoardGrid(lanes: [[["a"], ["b", "c"]], [[], ["d", "w"]]])
  return model
}

/// The Board after the clicks, in order.
@MainActor
private func board(clicking clicks: [(String, BoardClick)]) -> BoardModel {
  let model = board()
  for (id, click) in clicks { model.clickBoardCard(id, click) }
  return model
}

@Suite struct BoardSelectionClickMapping {
  @Test(
    arguments: [
      (1, [], true, BoardClick.select),
      (1, .option, true, .select),
      (1, .capsLock, true, .select),
      (1, .command, true, .toggle),
      (1, .shift, true, .extend),
      // ⌘ wins over ⇧.
      (1, [.command, .shift], true, .toggle),
      // The second click of a double click, whatever the modifiers.
      (2, [], true, .open),
      (2, .command, true, .open),
      (2, .shift, true, .open),
      (3, [], true, .open),
      // VoiceOver's press and a keyboard activation are not mouse events.
      (1, [], false, .open),
      (0, [], false, .open),
      (0, .command, false, .open),
      (0, .shift, false, .open),
    ] as [(Int, NSEvent.ModifierFlags, Bool, BoardClick)])
  func aClickMapsToItsAction(clickCount: Int, modifiers: NSEvent.ModifierFlags, isMouse: Bool, expected: BoardClick) {
    #expect(BoardClick.from(clickCount: clickCount, modifiers: modifiers, isMouse: isMouse) == expected)
  }
}

@MainActor
@Suite struct BoardSelectionCardClick {
  nonisolated static let staying: [BoardClick] = [.select, .toggle, .extend]

  /// Setting `selection` would leave the Board.
  @Test(arguments: staying)
  func aClickThatDoesNotOpenKeepsTheBoardShowing(_ click: BoardClick) {
    let model = board(clicking: [("a", .select)])

    model.clickBoardCard("c", click)

    #expect(model.selection == nil)
    #expect(model.visibleView == .board)
  }

  /// Return then opens the clicked card, as a double click does.
  @Test(arguments: staying)
  func aClickThatDoesNotOpenMovesTheFocusRingToTheCard(_ click: BoardClick) {
    let model = board(clicking: [("a", .select)])

    model.clickBoardCard("c", click)

    #expect(model.boardFocus == "c")
  }

  /// A scroll would move another card under a double click's second click.
  @Test(arguments: staying)
  func aClickThatDoesNotOpenDoesNotScrollTheBoard(_ click: BoardClick) {
    let model = board(clicking: [("a", .select)])
    let jumps = model.boardJumps

    model.clickBoardCard("c", click)

    #expect(model.boardJumps == jumps)
  }

  @Test func anArrowKeyScrollsTheBoardToTheFocusedCard() {
    let model = board(clicking: [("a", .select)])
    let jumps = model.boardJumps

    model.moveBoardFocus(.down)

    #expect(model.boardJumps == jumps + 1)
  }

  // MARK: Select

  @Test func aClickReplacesTheSelection() {
    let model = board(clicking: [("a", .select), ("d", .toggle)])

    model.clickBoardCard("c", .select)

    #expect(model.multiSelection == ["c"])
  }

  @Test func aClickSelectsADoneCard() {
    let model = board()

    model.clickBoardCard("z", .select)

    #expect(model.multiSelection == ["z"])
  }

  // MARK: Toggle

  @Test(
    arguments: [
      ([], "c", ["c"]),
      (["a"], "c", ["a", "c"]),
      (["a", "c"], "c", ["a"]),
      (["c"], "c", []),
      (["a"], "z", ["a", "z"]),
    ] as [([String], String, Set<String>)])
  func aCommandClickAddsOrRemovesTheCard(_ before: [String], _ id: String, _ after: Set<String>) {
    let model = board(clicking: before.map { ($0, .toggle) })

    model.clickBoardCard(id, .toggle)

    #expect(model.multiSelection == after)
  }

  /// With `a` as the anchor, ⇧-clicking `w` takes every card. With `c` it would leave out `b`.
  @Test func aCommandClickMovesTheAnchor() {
    let model = board(clicking: [("c", .select), ("a", .toggle)])

    model.clickBoardCard("w", .extend)

    #expect(model.multiSelection == ["a", "b", "c", "d", "w"])
  }

  // MARK: Extend

  @Test(
    arguments: [
      ("a", "c", ["a", "b", "c"]),
      // Across lanes, both ways.
      ("a", "w", ["a", "b", "c", "d", "w"]),
      ("w", "b", ["b", "c", "d", "w"]),
      ("c", "c", ["c"]),
    ] as [(String, String, Set<String>)])
  func aShiftClickAddsTheCardsFromTheAnchorInReadingOrder(_ anchor: String, _ id: String, _ after: Set<String>) {
    let model = board(clicking: [(anchor, .select)])

    model.clickBoardCard(id, .extend)

    #expect(model.multiSelection == after)
  }

  /// A ⇧-click adds to the selection and does not replace an earlier range.
  @Test func aShiftClickKeepsTheCardsOutsideItsRange() {
    let model = board(clicking: [("w", .select), ("a", .toggle)])

    model.clickBoardCard("b", .extend)

    #expect(model.multiSelection == ["a", "b", "w"])
  }

  /// The ways a ⇧-click finds no anchor in the reading order.
  enum NoAnchor: String, CaseIterable, Sendable {
    /// The sidebar or a refresh set the selection, so no click set an anchor.
    case noClick
    /// A Done card is not in the reading order.
    case doneCard
    /// Showing the Board again ends the Board selection.
    case boardShownAgain
    case escape

    @MainActor func arrange(_ model: BoardModel) {
      switch self {
      case .noClick: model.multiSelection = ["a"]
      case .doneCard: model.clickBoardCard("z", .select)
      case .boardShownAgain:
        model.clickBoardCard("a", .select)
        model.show(.board)
      case .escape:
        model.clickBoardCard("a", .select)
        model.clearBoardSelection()
      }
    }
  }

  @Test(arguments: NoAnchor.allCases)
  func aShiftClickWithoutAnAnchorInTheReadingOrderSelectsTheCard(_ shape: NoAnchor) {
    let model = board()
    shape.arrange(model)

    model.clickBoardCard("c", .extend)

    #expect(model.multiSelection == ["c"])
  }

  @Test func aShiftClickOnADoneCardSelectsIt() {
    let model = board(clicking: [("a", .select)])

    model.clickBoardCard("z", .extend)

    #expect(model.multiSelection == ["z"])
  }

  // MARK: Open

  /// A card with no Inbox item opens directly, which ends the Board selection.
  @Test func aDoubleClickOnACardOutsideTheInboxOpensTheSession() {
    let model = board(clicking: [("a", .select), ("b", .toggle)])

    model.clickBoardCard("w", .open)

    #expect(model.selection == "w")
    #expect(model.multiSelection.isEmpty)
  }

  @Test func aDoubleClickOnAnInboxCardShowsTheInboxOnIt() {
    let model = board(clicking: [("a", .select), ("b", .toggle)])

    model.clickBoardCard("c", .open)

    #expect(model.visibleView == .inbox)
    #expect(model.inboxFocus == "c")
    #expect(model.multiSelection.isEmpty)
  }
}

/// The ids that a drag of a card or its Move menu acts on.
@MainActor
@Suite struct BoardSelectionActionIDs {
  @Test func aSelectedCardActsOnTheSelectionInReadingOrder() {
    let model = board(clicking: [("w", .select), ("a", .toggle), ("c", .toggle)])

    #expect(model.boardActionIDs(for: "c") == ["a", "c", "w"])
  }

  /// A Done footer card is not in the reading order. It cannot be dragged and has no Move menu, so a drag of a
  /// lane card leaves it behind.
  @Test func aSelectedCardActsWithoutTheSelectedDoneCards() {
    let model = board(clicking: [("a", .select), ("z", .toggle), ("c", .toggle)])

    #expect(model.boardActionIDs(for: "a") == ["a", "c"])
  }

  @Test(
    arguments: [
      // A drag of an unselected card moves it alone and leaves the selection.
      (["a", "c"], "b"),
      ([], "b"),
      (["a"], "a"),
    ] as [([String], String)])
  func aCardActsAloneUnlessItIsInALargerSelection(_ selected: [String], _ id: String) {
    let model = board(clicking: selected.map { ($0, .toggle) })

    #expect(model.boardActionIDs(for: id) == [id])
  }
}

@Suite struct BoardSelectionDragPayload {
  @Test func thePayloadPutsOneIDOnEachLine() {
    #expect(BoardDrag.payload(["a", "b", "c"]) == "a\nb\nc")
  }

  @Test(arguments: [["a"], ["a", "b", "c"], ["session-1", "session-2"]])
  func theIDsOfAPayloadAreTheIDsItWasMadeFrom(_ ids: [String]) {
    #expect(BoardDrag.ids(from: BoardDrag.payload(ids)) == ids)
  }

  @Test(
    arguments: [
      ("a\n\nb\n", ["a", "b"]),
      ("\na", ["a"]),
      ("", []),
      ("\n\n", []),
      ("a\r\nb", ["a", "b"]),
    ] as [(String, [String])])
  func emptyLinesAreDropped(_ payload: String, _ ids: [String]) {
    #expect(BoardDrag.ids(from: payload) == ids)
  }
}

/// The selection rectangle's geometry, in the Board content's coordinate space.
@Suite struct BoardRectGeometry {
  /// Card `b` sits under `a` with a 10 pt gap, and `c` sits right of `a` with a 20 pt gap.
  static let frames: [String: CGRect] = [
    "a": CGRect(x: 0, y: 0, width: 100, height: 50),
    "b": CGRect(x: 0, y: 60, width: 100, height: 50),
    "c": CGRect(x: 120, y: 0, width: 100, height: 50),
  ]

  @Test(
    arguments: [
      (CGRect(x: 90, y: 40, width: 5, height: 5), ["a"]),
      (CGRect(x: 90, y: 10, width: 40, height: 10), ["a", "c"]),
      (CGRect(x: 50, y: 30, width: 100, height: 50), ["a", "b", "c"]),
      // One point of overlap counts.
      (CGRect(x: 99, y: 49, width: 2, height: 2), ["a"]),
      // The gaps between cards.
      (CGRect(x: 101, y: 0, width: 18, height: 200), []),
      (CGRect(x: 0, y: 51, width: 300, height: 8), []),
      // Edges that only touch a frame have zero overlap.
      (CGRect(x: 100, y: 0, width: 20, height: 50), []),
      (CGRect(x: 0, y: 50, width: 100, height: 10), []),
    ] as [(CGRect, [String])])
  func theHitsAreTheCardsWhoseFramesOverlapTheRect(_ rect: CGRect, _ hits: [String]) {
    #expect(BoardRect.hits(rect, frames: Self.frames).sorted() == hits)
  }

  @Test func noFramesGiveNoHits() {
    #expect(BoardRect.hits(CGRect(x: 0, y: 0, width: 500, height: 500), frames: [:]).isEmpty)
  }

  /// A drag can go up and left from where it started.
  @Test(
    arguments: [
      (CGPoint(x: 90, y: 10), CGPoint(x: 130, y: 20)),
      (CGPoint(x: 130, y: 20), CGPoint(x: 90, y: 10)),
      (CGPoint(x: 90, y: 20), CGPoint(x: 130, y: 10)),
      (CGPoint(x: 130, y: 10), CGPoint(x: 90, y: 20)),
    ])
  func aRectDrawnInAnyDirectionHitsTheSameCards(_ start: CGPoint, _ end: CGPoint) {
    let rect = BoardRect.rect(from: start, to: end)

    #expect(rect == CGRect(x: 90, y: 10, width: 40, height: 10))
    #expect(BoardRect.hits(rect, frames: Self.frames) == ["a", "c"])
  }
}

/// Whether a drag or a click starts on empty Board space. A start on a card belongs to the card's drag. A lane
/// header holds the lane's name and its controls. The pinned header holds the picker and the name field.
@Suite struct BoardRectStart {
  static let header = CGRect(x: 0, y: 0, width: 1200, height: 60)
  /// After a scroll, the pinned header sits at the top of the visible area, deep in the content.
  static let scrolledHeader = CGRect(x: 0, y: 1900, width: 1200, height: 60)
  /// Each lane's header spans the lane above its row of columns.
  static let laneHeaders = [
    CGRect(x: 16, y: 64, width: 1168, height: 28),
    CGRect(x: 16, y: 300, width: 1168, height: 28),
    CGRect(x: 16, y: 1960, width: 1168, height: 28),
  ]
  /// Lane 1 has `a` over `b` in its first column and `c` in the next. Lane 2 has an empty first column and `d` in
  /// the next. `e` is far down the Board in lane 3.
  static let frames: [String: CGRect] = [
    "a": CGRect(x: 16, y: 100, width: 180, height: 80),
    "b": CGRect(x: 16, y: 190, width: 180, height: 80),
    "c": CGRect(x: 208, y: 100, width: 180, height: 80),
    "d": CGRect(x: 208, y: 340, width: 180, height: 80),
    "e": CGRect(x: 208, y: 2000, width: 180, height: 80),
  ]

  struct Start: Sendable, CustomTestStringConvertible {
    var testDescription: String
    var point: CGPoint
    var header: CGRect = BoardRectStart.header
    var starts: Bool
  }

  @Test(
    arguments: [
      Start(testDescription: "a card's body", point: CGPoint(x: 106, y: 140), starts: false),
      Start(testDescription: "a card's PR link in its corner", point: CGPoint(x: 191, y: 175), starts: false),
      Start(testDescription: "a card's top left corner", point: CGPoint(x: 16, y: 100), starts: false),
      Start(testDescription: "a card in the second column", point: CGPoint(x: 290, y: 140), starts: false),
      Start(testDescription: "between two cards in a column", point: CGPoint(x: 106, y: 185), starts: true),
      Start(testDescription: "between two columns", point: CGPoint(x: 202, y: 140), starts: true),
      Start(testDescription: "below the last card in a column", point: CGPoint(x: 290, y: 250), starts: true),
      Start(testDescription: "the gap between lanes", point: CGPoint(x: 290, y: 285), starts: true),
      Start(testDescription: "between a lane header and its cards", point: CGPoint(x: 290, y: 96), starts: true),
      Start(testDescription: "right of the last column", point: CGPoint(x: 900, y: 140), starts: true),
      Start(
        testDescription: "the far left of a card row past the padding", point: CGPoint(x: 17, y: 380),
        starts: true),
      Start(
        testDescription: "the left of a card row below a lane header", point: CGPoint(x: 100, y: 380), starts: true),
      Start(testDescription: "a lane header's name", point: CGPoint(x: 40, y: 78), starts: false),
      Start(testDescription: "a lane header's controls", point: CGPoint(x: 1100, y: 78), starts: false),
      Start(testDescription: "a lane header's top left corner", point: CGPoint(x: 16, y: 64), starts: false),
      Start(testDescription: "a lane header's bottom edge", point: CGPoint(x: 290, y: 92), starts: true),
      Start(testDescription: "the second lane's header", point: CGPoint(x: 290, y: 314), starts: false),
      Start(testDescription: "the header", point: CGPoint(x: 290, y: 30), starts: false),
      Start(testDescription: "the header's left edge", point: CGPoint(x: 0, y: 30), starts: false),
      Start(testDescription: "the header's bottom edge", point: CGPoint(x: 290, y: 60), starts: true),
      Start(
        testDescription: "a card after a scroll", point: CGPoint(x: 290, y: 2040), header: scrolledHeader,
        starts: false),
      Start(
        testDescription: "under a card after a scroll", point: CGPoint(x: 290, y: 2100), header: scrolledHeader,
        starts: true),
      Start(
        testDescription: "the header after a scroll", point: CGPoint(x: 900, y: 1930), header: scrolledHeader,
        starts: false),
      Start(
        testDescription: "a lane header deep in the content after a scroll", point: CGPoint(x: 290, y: 1974),
        header: scrolledHeader, starts: false),
      Start(
        testDescription: "where the header was before a scroll", point: CGPoint(x: 900, y: 30),
        header: scrolledHeader, starts: true),
    ])
  func aSelectionStartsOnlyOnEmptyBoardSpace(_ start: Start) {
    let starts = BoardRect.startsSelection(
      at: start.point, frames: Self.frames, blocked: [start.header] + Self.laneHeaders)

    #expect(starts == start.starts)
  }
}

/// The scroll step while a rectangle drag's pointer is near an edge. The pointer is in the visible area's
/// coordinates, with y increasing downward.
@Suite struct BoardRectAutoscroll {
  static let visible = CGSize(width: 800, height: 600)
  static let headerHeight: CGFloat = 60

  static func delta(_ x: CGFloat, _ y: CGFloat) -> CGVector {
    BoardRect.autoscrollDelta(pointer: CGPoint(x: x, y: y), visible: visible, headerHeight: headerHeight)
  }

  static func sign(_ value: CGFloat) -> Int { value > 0 ? 1 : value < 0 ? -1 : 0 }

  struct Pointer: Sendable, CustomTestStringConvertible {
    var testDescription: String
    var x: CGFloat
    var y: CGFloat
    /// The signs of the step's dx and dy.
    var direction: [Int]
  }

  @Test(
    arguments: [
      Pointer(testDescription: "the middle", x: 400, y: 300, direction: [0, 0]),
      Pointer(testDescription: "just outside the bottom zone", x: 400, y: 570, direction: [0, 0]),
      Pointer(testDescription: "just outside the right zone", x: 770, y: 300, direction: [0, 0]),
      Pointer(testDescription: "just outside the left zone", x: 30, y: 300, direction: [0, 0]),
      // The top zone starts at the header's bottom edge, not at the top of the visible area.
      Pointer(testDescription: "just below the top zone", x: 400, y: 90, direction: [0, 0]),
      Pointer(testDescription: "the top zone under the header", x: 400, y: 70, direction: [0, -1]),
      Pointer(testDescription: "over the header", x: 400, y: 30, direction: [0, -1]),
      Pointer(testDescription: "the bottom zone", x: 400, y: 590, direction: [0, 1]),
      Pointer(testDescription: "past the bottom edge", x: 400, y: 620, direction: [0, 1]),
      Pointer(testDescription: "the right zone", x: 790, y: 300, direction: [1, 0]),
      Pointer(testDescription: "the left zone", x: 10, y: 300, direction: [-1, 0]),
      Pointer(testDescription: "the bottom right corner", x: 790, y: 590, direction: [1, 1]),
    ])
  func thePointerScrollsTowardTheEdgeOnlyInsideAZone(_ pointer: Pointer) {
    let delta = Self.delta(pointer.x, pointer.y)

    #expect([Self.sign(delta.dx), Self.sign(delta.dy)] == pointer.direction)
  }

  @Test(
    arguments: [
      (CGPoint(x: 400, y: 580), CGPoint(x: 400, y: 595)),
      (CGPoint(x: 400, y: 80), CGPoint(x: 400, y: 65)),
      (CGPoint(x: 780, y: 300), CGPoint(x: 795, y: 300)),
      (CGPoint(x: 20, y: 300), CGPoint(x: 5, y: 300)),
    ])
  func aDeeperPointerScrollsFaster(_ shallow: CGPoint, _ deep: CGPoint) {
    let slow = Self.delta(shallow.x, shallow.y)
    let fast = Self.delta(deep.x, deep.y)

    #expect(hypot(fast.dx, fast.dy) > hypot(slow.dx, slow.dy))
  }
}

/// The selection that a rectangle drag sets as it grows and shrinks.
@MainActor
@Suite struct BoardRectSelection {
  @Test func aPlainDragReplacesTheSelectionWithTheHits() {
    let model = board(clicking: [("w", .select)])

    model.selectBoardRect(["a", "b"], adding: [])

    #expect(model.multiSelection == ["a", "b"])
  }

  @Test func aCommandDragAddsTheHitsToTheSelectionAtItsStart() {
    let model = board(clicking: [("w", .select)])

    model.selectBoardRect(["a", "b"], adding: ["w"])

    #expect(model.multiSelection == ["a", "b", "w"])
  }

  @Test(
    arguments: [
      // A plain drag.
      ([], ["a", "b", "c"], ["a"], ["a"]),
      // A ⌘-drag keeps the selection at its start.
      (["w"], ["a", "b", "c"], ["a"], ["a", "w"]),
      // A card in the start selection stays when the rect leaves it.
      (["b"], ["a", "b"], [], ["b"]),
    ] as [(Set<String>, Set<String>, Set<String>, Set<String>)])
  func shrinkingTheRectDeselectsTheCardsItLeaves(
    _ base: Set<String>, _ grown: Set<String>, _ shrunk: Set<String>, _ after: Set<String>
  ) {
    let model = board()
    model.selectBoardRect(grown, adding: base)

    model.selectBoardRect(shrunk, adding: base)

    #expect(model.multiSelection == after)
  }

  @Test func aDragThatHitsNothingLeavesTheBoardShowingWithNoSelection() {
    let model = board(clicking: [("w", .select)])

    model.selectBoardRect([], adding: [])

    #expect(model.multiSelection.isEmpty)
    #expect(model.visibleView == .board)
  }

  @Test func aDragKeepsTheBoardShowing() {
    let model = board()

    model.selectBoardRect(["a", "b"], adding: [])

    #expect(model.selection == nil)
    #expect(model.visibleView == .board)
  }

  /// With `a` as the anchor, ⇧-clicking `w` takes every card. With `c` it would leave out `b`.
  @Test func theFirstHitInReadingOrderBecomesTheAnchor() {
    let model = board()
    model.selectBoardRect(["c", "a"], adding: [])

    model.clickBoardCard("w", .extend)

    #expect(model.multiSelection == ["a", "b", "c", "d", "w"])
  }

  @Test func aDragLeavesTheFocusRing() {
    let model = board(clicking: [("d", .select)])

    model.selectBoardRect(["a", "b"], adding: [])

    #expect(model.boardFocus == "d")
  }
}

/// Escape, Space, and ⇧-arrow on the focused Board.
@MainActor
@Suite struct BoardSelectionKeys {
  // MARK: Escape

  @Test(arguments: [[], ["a"], ["a", "c", "z"]] as [[String]])
  func escapeClearsTheSelection(_ selected: [String]) {
    let model = board(clicking: selected.map { ($0, .toggle) })

    model.clearBoardSelection()

    #expect(model.multiSelection.isEmpty)
  }

  @Test func escapeKeepsTheBoardShowing() {
    let model = board(clicking: [("a", .select), ("c", .toggle)])

    model.clearBoardSelection()

    #expect(model.visibleView == .board)
  }

  // MARK: Space

  @Test(
    arguments: [
      ("b", [], ["b"]),
      ("b", ["b", "c"], ["c"]),
      ("b", ["a"], ["a", "b"]),
      // No ring, or a ring on a card the Board no longer draws, starts on the first card.
      (nil, [], ["a"]),
      ("gone", [], ["a"]),
    ] as [(String?, Set<String>, Set<String>)])
  func spaceTogglesTheFocusedCard(_ focus: String?, _ before: Set<String>, _ after: Set<String>) {
    let model = board()
    model.multiSelection = before
    model.boardFocus = focus

    model.toggleFocusedBoardCard()

    #expect(model.multiSelection == after)
  }

  /// Space acts as a ⌘-click on the focused card, so a ⇧-click extends from it.
  @Test func spaceSetsTheAnchor() {
    let model = board()
    model.boardFocus = "c"
    model.toggleFocusedBoardCard()

    model.clickBoardCard("a", .extend)

    #expect(model.multiSelection == ["a", "b", "c"])
  }

  // MARK: ⇧-arrow

  @Test(
    arguments: [
      ("a", BoardDirection.right, "b"),
      ("b", .down, "c"),
      // Down from the end of lane 1's second column to lane 2's.
      ("c", .down, "d"),
      ("d", .up, "c"),
    ] as [(String, BoardDirection, String)])
  func shiftArrowMovesTheFocusRing(_ from: String, _ direction: BoardDirection, _ to: String) {
    let model = board(clicking: [(from, .select)])

    model.extendBoardSelection(direction)

    #expect(model.boardFocus == to)
  }

  @Test(
    arguments: [
      ("a", [BoardDirection.right], ["a", "b"]),
      ("a", [.right, .down], ["a", "b", "c"]),
      ("b", [.down, .down], ["b", "c", "d"]),
      ("d", [.up], ["c", "d"]),
      // The ring cannot move left of the first column.
      ("a", [.left], ["a"]),
    ] as [(String, [BoardDirection], Set<String>)])
  func shiftArrowAddsTheCardsFromTheAnchorToTheRing(
    _ anchor: String, _ directions: [BoardDirection], _ after: Set<String>
  ) {
    let model = board(clicking: [(anchor, .select)])

    for direction in directions { model.extendBoardSelection(direction) }

    #expect(model.multiSelection == after)
  }

  @Test func shiftArrowKeepsTheCardsOutsideItsRange() {
    let model = board(clicking: [("w", .select), ("a", .toggle)])

    model.extendBoardSelection(.right)

    #expect(model.multiSelection == ["a", "b", "w"])
  }

  /// With no anchor, the card the ring leaves becomes the anchor, as ⇧-arrow does in a Finder list.
  @Test func shiftArrowWithoutAnAnchorSelectsTheCardItLeftAndTheNewOne() {
    let model = board()
    model.boardFocus = "b"

    model.extendBoardSelection(.down)

    #expect(model.multiSelection == ["b", "c"])
  }
}

/// The frames that `BoardGeometry` keeps when card views go away.
@MainActor
@Suite struct BoardGeometryFrames {
  static let old = CGRect(x: 0, y: 0, width: 100, height: 50)
  static let new = CGRect(x: 0, y: 300, width: 100, height: 50)

  @Test func aCardThatGoesAwayLosesItsFrame() {
    let geometry = BoardGeometry()
    geometry.record("a", Self.old)

    geometry.dropFrame("a", ifStill: Self.old)

    #expect(geometry.frames["a"] == nil)
  }

  /// A card that a lazy lane removes during an autoscroll stays reachable by the rectangle.
  @Test func aCardThatGoesAwayWhileARectangleIsDrawnKeepsItsFrame() {
    let geometry = BoardGeometry()
    geometry.record("a", Self.old)
    geometry.marqueeActive = true

    geometry.dropFrame("a", ifStill: Self.old)

    #expect(geometry.frames["a"] == Self.old)
  }

  /// A card that a lazy lane removed during a rectangle and that never drew again loses its frame when the
  /// rectangle ends. Otherwise a later rectangle could select a session that the Board no longer draws.
  @Test func aCardThatWentAwayDuringARectangleLosesItsFrameWhenTheRectangleEnds() {
    let geometry = BoardGeometry()
    geometry.record("a", Self.old)
    geometry.marqueeActive = true
    geometry.dropFrame("a", ifStill: Self.old)

    geometry.marqueeActive = false

    #expect(geometry.frames["a"] == nil)
  }

  /// A card that scrolls away and back during one rectangle reports the same content-space frame again.
  @Test func aCardThatDrewAgainDuringARectangleKeepsItsFrameWhenTheRectangleEnds() {
    let geometry = BoardGeometry()
    geometry.record("a", Self.old)
    geometry.marqueeActive = true
    geometry.dropFrame("a", ifStill: Self.old)
    geometry.record("a", Self.old)

    geometry.marqueeActive = false

    #expect(geometry.frames["a"] == Self.old)
  }

  /// A second view that draws the same card can report its frame before the first view goes away.
  @Test func aCardThatAnotherViewRedrewKeepsTheNewFrame() {
    let geometry = BoardGeometry()
    geometry.record("a", Self.new)

    geometry.dropFrame("a", ifStill: Self.old)

    #expect(geometry.frames["a"] == Self.new)
  }

  @Test func aViewThatNeverReportedAFrameRemovesNothing() {
    let geometry = BoardGeometry()
    geometry.record("a", Self.old)

    geometry.dropFrame("a", ifStill: nil)

    #expect(geometry.frames["a"] == Self.old)
  }

  @Test func aLaneHeaderThatGoesAwayLosesItsFrame() {
    let geometry = BoardGeometry()
    geometry.recordLaneHeader("lane", Self.old)

    geometry.dropLaneHeader("lane", ifStill: Self.old)

    #expect(geometry.laneHeaders["lane"] == nil)
  }

  /// A second view that draws the same lane can report its header frame before the first view goes away.
  @Test func aLaneHeaderThatAnotherViewRedrewKeepsTheNewFrame() {
    let geometry = BoardGeometry()
    geometry.recordLaneHeader("lane", Self.new)

    geometry.dropLaneHeader("lane", ifStill: Self.old)

    #expect(geometry.laneHeaders["lane"] == Self.new)
  }
}
