import SwiftUI
import Testing

@testable import SwitchboardApp

@Suite struct KeyboardNavigationTests {
  // MARK: ListStep

  @Suite struct ListSteps {
    let abc = ["a", "b", "c"]

    @Test(arguments: [nil, "a"] as [String?], [1, -1])
    func anEmptyListGivesNilInBothModes(from: String?, step: Int) {
      #expect(ListStep.step([], from: from, by: step, wrap: true) == nil)
      #expect(ListStep.step([], from: from, by: step, wrap: false) == nil)
    }

    /// An id that the list lacks, as after the poll removed it, counts as no current item.
    @Test(arguments: [nil, "gone"] as [String?], [true, false])
    func nextWithNoCurrentItemGivesTheFirst(from: String?, wrap: Bool) {
      #expect(ListStep.step(abc, from: from, by: 1, wrap: wrap) == "a")
    }

    @Test(arguments: [nil, "gone"] as [String?], [true, false])
    func previousWithNoCurrentItemGivesTheLast(from: String?, wrap: Bool) {
      #expect(ListStep.step(abc, from: from, by: -1, wrap: wrap) == "c")
    }

    @Test(arguments: [true, false])
    func nextFromTheMiddleGivesTheFollowingItem(wrap: Bool) {
      #expect(ListStep.step(abc, from: "b", by: 1, wrap: wrap) == "c")
    }

    @Test(arguments: [true, false])
    func previousFromTheMiddleGivesTheItemBefore(wrap: Bool) {
      #expect(ListStep.step(abc, from: "b", by: -1, wrap: wrap) == "a")
    }

    @Test func nextFromTheLastStaysThereWithoutWrap() {
      #expect(ListStep.step(abc, from: "c", by: 1, wrap: false) == "c")
    }

    @Test func previousFromTheFirstStaysThereWithoutWrap() {
      #expect(ListStep.step(abc, from: "a", by: -1, wrap: false) == "a")
    }

    @Test func nextFromTheLastWrapsToTheFirst() {
      #expect(ListStep.step(abc, from: "c", by: 1, wrap: true) == "a")
    }

    @Test func previousFromTheFirstWrapsToTheLast() {
      #expect(ListStep.step(abc, from: "a", by: -1, wrap: true) == "c")
    }

    @Test(arguments: [nil, "only", "gone"] as [String?], [1, -1])
    func aOneItemListGivesThatItemInEveryCase(from: String?, step: Int) {
      #expect(ListStep.step(["only"], from: from, by: step, wrap: true) == "only")
      #expect(ListStep.step(["only"], from: from, by: step, wrap: false) == "only")
    }

    /// `moveInbox` stepped with this formula before it called `ListStep`.
    @Test(arguments: 0...5, [1, -1])
    func wrapAgreesWithTheOldInboxFormula(count: Int, step: Int) {
      let ids = (0..<count).map { "i\($0)" }

      let indices: [Int?] = [nil] + ids.indices.map { Optional($0) }
      for index in indices {
        let from = index.map { ids[$0] }
        let i = index ?? (step > 0 ? -1 : 0)
        let expected = count == 0 ? nil : ids[((i + step) % count + count) % count]

        #expect(ListStep.step(ids, from: from, by: step, wrap: true) == expected, "from \(String(describing: from))")
      }
    }
  }

  // MARK: BoardGrid

  @Suite struct BoardGridMoves {
    static let directions: [BoardDirection] = [.up, .down, .left, .right]

    @Test(arguments: directions)
    func anEmptyGridGivesNil(_ direction: BoardDirection) {
      #expect(BoardGrid(lanes: []).move(from: nil, direction) == nil)
      #expect(BoardGrid(lanes: []).move(from: "gone", direction) == nil)
    }

    /// An empty group's lane has a cell for every column and no cards.
    @Test(arguments: directions)
    func aGridOfEmptyCellsGivesNil(_ direction: BoardDirection) {
      let grid = BoardGrid(lanes: [[[], [], []], [[], [], []]])

      #expect(grid.move(from: nil, direction) == nil)
    }

    @Test(arguments: directions)
    func aLoneCardStaysPut(_ direction: BoardDirection) {
      let grid = BoardGrid(lanes: [[[], ["a"], []], [[], [], []]])

      #expect(grid.move(from: "a", direction) == "a")
    }

    @Test func downMovesDownTheStack() {
      let grid = BoardGrid(lanes: [[["a", "b", "c"]]])

      #expect(grid.move(from: "a", .down) == "b")
    }

    @Test func downFromTheBottomOfAStackGoesToTheTopOfTheSameColumnInTheNextLane() {
      let grid = BoardGrid(lanes: [
        [["a"], ["b", "c"], ["x"]],
        [["d"], ["e", "f"], ["g"]],
      ])

      #expect(grid.move(from: "c", .down) == "e")
    }

    @Test func downGoesToTheNearestColumnWhenTheSameColumnIsEmpty() {
      let grid = BoardGrid(lanes: [
        [["a"], [], [], []],
        [[], [], ["near"], ["far"]],
      ])

      #expect(grid.move(from: "a", .down) == "near")
    }

    @Test func downGoesToTheNearestColumnOnTheLeft() {
      let grid = BoardGrid(lanes: [
        [[], [], [], ["a"]],
        [["far"], ["near"], [], []],
      ])

      #expect(grid.move(from: "a", .down) == "near")
    }

    @Test func downBreaksATieBetweenTwoNearestColumnsToTheLeft() {
      let grid = BoardGrid(lanes: [
        [[], ["a"], []],
        [["left"], [], ["right"]],
      ])

      #expect(grid.move(from: "a", .down) == "left")
    }

    /// A lane with no cards may have a cell per column or no cells.
    @Test(arguments: [[[], [], []], []] as [[[String]]])
    func downSkipsALaneWithNoCards(_ empty: [[String]]) {
      let grid = BoardGrid(lanes: [[["a"], [], []], empty, [["b"], [], []]])

      #expect(grid.move(from: "a", .down) == "b")
    }

    @Test func downFromTheBottomOfTheLastLaneStays() {
      let grid = BoardGrid(lanes: [[["a"]], [["b", "c"]]])

      #expect(grid.move(from: "c", .down) == "c")
    }

    @Test func downStaysWhenEveryLaterLaneIsEmpty() {
      let grid = BoardGrid(lanes: [[["a"], []], [[], []]])

      #expect(grid.move(from: "a", .down) == "a")
    }

    @Test func upMovesUpTheStack() {
      let grid = BoardGrid(lanes: [[["a", "b", "c"]]])

      #expect(grid.move(from: "c", .up) == "b")
    }

    @Test func upFromTheTopOfAStackGoesToTheBottomCardOfTheCellAbove() {
      let grid = BoardGrid(lanes: [
        [["a", "b", "c"], ["x"]],
        [["d", "e"], ["y"]],
      ])

      #expect(grid.move(from: "d", .up) == "c")
    }

    @Test func upBreaksATieBetweenTwoNearestColumnsToTheLeftAndTakesTheBottomCard() {
      let grid = BoardGrid(lanes: [
        [["l1", "l2"], [], ["r1", "r2"]],
        [[], ["a"], []],
      ])

      #expect(grid.move(from: "a", .up) == "l2")
    }

    @Test(arguments: [[[], [], []], []] as [[[String]]])
    func upSkipsALaneWithNoCards(_ empty: [[String]]) {
      let grid = BoardGrid(lanes: [[["a"], [], []], empty, [["b"], [], []]])

      #expect(grid.move(from: "b", .up) == "a")
    }

    @Test func upFromTheTopOfTheFirstLaneStays() {
      let grid = BoardGrid(lanes: [[["a", "b"]], [["c"]]])

      #expect(grid.move(from: "a", .up) == "a")
    }

    /// Columns: a0 a1 a2 | (empty) | c0 c1 c2 | d0.
    static let sideways = BoardGrid(lanes: [[["a0", "a1", "a2"], [], ["c0", "c1", "c2"], ["d0"]]])

    @Test func rightSkipsAnEmptyColumnAndKeepsTheStackIndex() {
      #expect(Self.sideways.move(from: "a1", .right) == "c1")
    }

    @Test func leftSkipsAnEmptyColumnAndKeepsTheStackIndex() {
      #expect(Self.sideways.move(from: "c2", .left) == "a2")
    }

    @Test func rightClampsTheStackIndexToAShorterCell() {
      #expect(Self.sideways.move(from: "c2", .right) == "d0")
    }

    @Test func leftClampsTheStackIndexToAShorterCell() {
      let grid = BoardGrid(lanes: [[["a0"], ["b0", "b1", "b2"]]])

      #expect(grid.move(from: "b2", .left) == "a0")
    }

    @Test func rightAtTheRightEdgeStays() {
      #expect(Self.sideways.move(from: "d0", .right) == "d0")
    }

    @Test func leftAtTheLeftEdgeStays() {
      #expect(Self.sideways.move(from: "a1", .left) == "a1")
    }

    /// The other lane has a card further along, but sideways moves never change lanes.
    @Test func rightWithNoCardFurtherInTheSameLaneStays() {
      let grid = BoardGrid(lanes: [[["a"], [], []], [[], [], ["b"]]])

      #expect(grid.move(from: "a", .right) == "a")
    }

    @Test func leftWithNoCardFurtherInTheSameLaneStays() {
      let grid = BoardGrid(lanes: [[["a"], [], []], [[], [], ["b"]]])

      #expect(grid.move(from: "b", .left) == "b")
    }

    /// A focus id that the poll removed counts as no focus at all.
    @Test(arguments: [nil, "gone"] as [String?], [BoardDirection.down, .right])
    func downOrRightWithNoCurrentCardGoesToTheFirst(from: String?, direction: BoardDirection) {
      let grid = BoardGrid(lanes: [[[], ["a", "b"]], [["c"], ["d"]]])

      #expect(grid.move(from: from, direction) == "a")
    }

    @Test(arguments: [nil, "gone"] as [String?], [BoardDirection.up, .left])
    func upOrLeftWithNoCurrentCardGoesToTheLast(from: String?, direction: BoardDirection) {
      let grid = BoardGrid(lanes: [[[], ["a", "b"]], [["c"], ["d"]], [[], []]])

      #expect(grid.move(from: from, direction) == "d")
    }
  }

  // MARK: BoardGrid reachability and order

  @Suite struct BoardGridShape {
    static let grids: [[[[String]]]] = [
      // Sparse columns.
      [[["a"], [], ["b"], []], [[], ["c"], [], ["d"]], [["e"], [], [], []]],
      // Empty lanes, with and without cells, around and between the cards.
      [[[], [], []], [["a"], [], []], [], [[], [], []], [[], [], ["b"]], [[], [], []]],
      // One long stack.
      [[["a", "b", "c", "d", "e"]]],
      // A lane whose only card is in the last column.
      [[["a", "b"], ["c"], [], []], [[], [], [], ["z"]]],
      // Stacks of different heights, with a card under an empty cell in every lane.
      [[["a0", "a1", "a2"], [], ["b0"]], [[], ["c0", "c1"], []], [["d0"], [], ["e0", "e1", "e2", "e3"]]],
    ]

    /// Every card the four moves reach, starting from `start`.
    func reached(_ grid: BoardGrid, from start: String) -> Set<String> {
      var seen: Set<String> = [start]
      var queue = [start]
      while let id = queue.popLast() {
        for direction in BoardGridMoves.directions {
          if let next = grid.move(from: id, direction), seen.insert(next).inserted { queue.append(next) }
        }
      }
      return seen
    }

    @Test(arguments: grids)
    func arrowsFromTheFirstCardReachEveryCard(_ lanes: [[[String]]]) throws {
      let grid = BoardGrid(lanes: lanes)
      let first = try #require(grid.first)

      #expect(reached(grid, from: first) == Set(lanes.flatMap { $0.flatMap { $0 } }))
    }

    /// From any card, the arrows reach every card.
    @Test(arguments: grids)
    func arrowsFromAnyCardReachEveryCard(_ lanes: [[[String]]]) {
      let grid = BoardGrid(lanes: lanes)
      let all = Set(lanes.flatMap { $0.flatMap { $0 } })

      for id in all {
        #expect(reached(grid, from: id) == all, "from \(id)")
      }
    }

    @Test func readingOrderGoesLaneByLaneThenColumnByColumnThenDownTheStack() {
      let grid = BoardGrid(lanes: [
        [["a"], [], ["b", "c"]],
        [],
        [["d", "e"], ["f"], []],
      ])

      #expect(grid.readingOrder == ["a", "b", "c", "d", "e", "f"])
    }

    @Test(arguments: grids)
    func firstAndLastAreTheEndsOfTheReadingOrder(_ lanes: [[[String]]]) {
      let grid = BoardGrid(lanes: lanes)

      #expect(grid.first == grid.readingOrder.first)
      #expect(grid.last == grid.readingOrder.last)
    }

    @Test func anEmptyGridHasNoFirstLastOrReadingOrder() {
      let grid = BoardGrid(lanes: [[[], []], []])

      #expect(grid.first == nil)
      #expect(grid.last == nil)
      #expect(grid.readingOrder.isEmpty)
    }

    @Test func containsOnlyTheIdsInItsCells() {
      let grid = BoardGrid(lanes: [[["a"], []], [[], ["b"]]])

      #expect(grid.contains("a"))
      #expect(grid.contains("b"))
      #expect(!grid.contains("gone"))
    }
  }

  // MARK: NavKey

  @Suite struct NavKeys {
    static let mapped: [(KeyEquivalent, NavAction)] = [
      (.upArrow, .move(.up)), (.downArrow, .move(.down)), (.leftArrow, .move(.left)),
      (.rightArrow, .move(.right)), (.return, .open),
    ]

    /// Every combination of Command, Option, Control, and Shift that has at least one of them.
    static let anyOfTheFour = ReturnKeyTests.allModifiers.filter { !$0.isEmpty }

    @Test(arguments: mapped)
    func aPlainKeyDoesItsAction(_ key: KeyEquivalent, _ expected: NavAction) {
      #expect(NavKey.action(key, modifiers: []) == expected)
    }

    /// Menu shortcuts and ⇧-arrow text selection keep their keys.
    @Test(arguments: mapped.map(\.0), anyOfTheFour)
    func aMappedKeyWithCommandOptionControlOrShiftIsLeftAlone(_ key: KeyEquivalent, _ modifiers: EventModifiers) {
      #expect(NavKey.action(key, modifiers: modifiers) == nil)
    }

    /// macOS sends arrow keys with the numeric pad and function flags set.
    @Test(arguments: mapped, [EventModifiers.capsLock, .numericPad, .function, [.numericPad, .function]])
    func flagsOtherThanTheFourChangeNothing(_ mapping: (KeyEquivalent, NavAction), _ modifiers: EventModifiers) {
      #expect(NavKey.action(mapping.0, modifiers: modifiers) == mapping.1)
    }

    @Test(arguments: [
      KeyEquivalent("j"), KeyEquivalent("k"), KeyEquivalent("h"), KeyEquivalent("l"), KeyEquivalent("a"),
      .escape, .tab, .space, .delete, .home, .end, .pageUp, .pageDown,
    ])
    func anUnmappedKeyIsLeftAlone(_ key: KeyEquivalent) {
      #expect(NavKey.action(key, modifiers: []) == nil)
    }
  }

  // MARK: NavShortcuts

  @Suite struct Shortcuts {
    static let all = NavShortcuts.all

    /// The key as a US keyboard types it. AppKit can store ⇧⌘] as ⌘}, and both name one key press.
    struct Press: Equatable {
      var key: Character
      var modifiers: EventModifiers

      init(_ key: Character, _ modifiers: EventModifiers = .command) {
        let shifted: [Character: Character] = ["}": "]", "{": "["]
        if let base = shifted[key] {
          self.key = base
          self.modifiers = modifiers.union(.shift)
        } else {
          self.key = Character(key.lowercased())
          self.modifiers = modifiers
        }
      }

      init(_ shortcut: KeyboardShortcut) { self.init(shortcut.key.character, shortcut.modifiers) }
    }

    /// The app's other shortcuts, and the standard menu items every Mac app has. ⌘P is the macOS Print key,
    /// which SwiftUI may add to the default File menu.
    static let taken: [Press] = [
      Press("1"), Press("2"), Press("j"), Press("n"), Press("i", [.command, .shift]), Press("g", [.command, .shift]),
      Press("m", [.command, .shift]), Press("."), Press("r", [.command, .shift]), Press("d", [.command, .shift]),
      Press("a", [.command, .shift]), Press(KeyEquivalent.return.character),
      Press(KeyEquivalent.return.character, [.command, .shift]), Press("r"),
      Press("q"), Press("w"), Press("h"), Press("h", [.command, .option]), Press("m"), Press(","), Press("c"),
      Press("v"), Press("x"), Press("a"), Press("z"), Press("z", [.command, .shift]), Press("f", [.command, .control]),
      Press("p"),
    ]

    /// A focused terminal passes only ⌘ keys to the menu bar.
    @Test func everyShortcutUsesCommand() {
      for shortcut in Self.all {
        #expect(shortcut.modifiers.contains(.command), "\(shortcut.key.character)")
      }
    }

    @Test func noTwoShortcutsShareAKeyPress() {
      let presses = Self.all.map(Press.init)

      #expect(Set(presses.map { "\($0.key) \($0.modifiers.rawValue)" }).count == presses.count)
    }

    @Test func noShortcutTakesAKeyThatIsAlreadyUsed() {
      for shortcut in Self.all {
        #expect(!Self.taken.contains(Press(shortcut)), "\(shortcut.key.character)")
      }
    }

    @Test func theShortcutsAreTheKeysTheReadmeNames() {
      #expect(Press(NavShortcuts.nextSession) == Press("]", [.command, .shift]))
      #expect(Press(NavShortcuts.previousSession) == Press("[", [.command, .shift]))
      #expect(Press(NavShortcuts.focusList) == Press("l"))
      #expect(Press(NavShortcuts.focusTerminal) == Press("t"))
      #expect(Press(NavShortcuts.searchSessions) == Press("k"))
    }
  }
}
