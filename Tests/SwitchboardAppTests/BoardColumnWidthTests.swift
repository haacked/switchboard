import CoreGraphics
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardColumnWidth {
  /// The width that `columns` columns draw with the gaps between them, the padding, and a legacy vertical scroller.
  /// A lane row holds only its columns, so `columns` columns have `columns - 1` gaps.
  private func drawnWidth(_ columnWidth: CGFloat, columns: Int = 5) -> CGFloat {
    BoardView.legacyScrollerWidth + 2 * BoardView.boardPadding + CGFloat(columns) * columnWidth
      + CGFloat(columns - 1) * BoardView.columnSpacing
  }

  /// The narrowest Board that draws every column at `minColumnWidth` without scrolling sideways.
  private var exactFitWidth: CGFloat { drawnWidth(BoardView.minColumnWidth) }

  @Test func fillsAWideBoard() {
    let width = BoardView.fittedColumnWidth(available: 1268, columns: 5)

    #expect(width > BoardView.minColumnWidth && width < BoardView.maxColumnWidth)
    #expect(abs(drawnWidth(width) - 1268) < 0.01)
  }

  @Test(arguments: [1, 2, 3, 4, 6])
  func fillsAWideBoardWithAnyColumnCount(_ columns: Int) {
    let available = drawnWidth(200, columns: columns)

    let width = BoardView.fittedColumnWidth(available: available, columns: columns)

    #expect(abs(width - 200) < 0.01)
  }

  @Test func neverDrawsWiderThanTheMaximum() {
    #expect(BoardView.fittedColumnWidth(available: 4000, columns: 5) == BoardView.maxColumnWidth)
  }

  @Test func fitsEveryColumnInA1024PointWindow() {
    let available = 1024 - ContentView.sidebarIdealWidth
    let width = BoardView.fittedColumnWidth(available: available, columns: 5)

    #expect(drawnWidth(width) <= available + 0.01)
  }

  @Test func fitsEveryColumnInTheDefaultWindow() {
    // The default 1,400 pt window leaves about 1,090 pt for the Board beside a 300 pt sidebar.
    // A legacy vertical scroller takes its width out of those 1,090 pt.
    #expect(BoardView.legacyScrollerWidth > 0)
    #expect(drawnWidth(BoardView.fittedColumnWidth(available: 1090, columns: 5)) <= 1090 + 0.01)
  }

  @Test func fiveMinimumColumnsFillTheirExactWidth() {
    let width = BoardView.fittedColumnWidth(available: exactFitWidth, columns: 5)

    #expect(abs(width - BoardView.minColumnWidth) < 0.01)
    #expect(abs(drawnWidth(width) - exactFitWidth) < 0.01)
  }

  @Test func extraWidthPastTheExactFitSplitsAcrossTheColumns() {
    // Five columns share the 10 extra points.
    let width = BoardView.fittedColumnWidth(available: exactFitWidth + 10, columns: 5)

    #expect(abs(width - (BoardView.minColumnWidth + 2)) < 0.01)
  }

  @Test func aBoardOnePointNarrowerThanTheExactFitDrawsTheMinimum() {
    #expect(BoardView.fittedColumnWidth(available: exactFitWidth - 1, columns: 5) == BoardView.minColumnWidth)
  }

  @Test func aBoardWithNoColumnsDrawsTheMinimum() {
    #expect(BoardView.fittedColumnWidth(available: 1090, columns: 0) == BoardView.minColumnWidth)
  }
}
