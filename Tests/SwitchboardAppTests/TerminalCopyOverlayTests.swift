import AppKit
import SwiftTerm
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The rows that Claude Code v2.1.322 drew in a 90-column tmux pane for `markdown`, as `tmux capture-pane -e`
/// printed them.
private let claudeRows = [
  "\u{1B}[38;5;231m\u{1B}[49m⏺\u{1B}[39m Here is code:",
  "",
  "  \u{1B}[34mfunc\u{1B}[39m \u{1B}[33mgreet\u{1B}[39m(name: \u{1B}[2m\u{1B}[36mString\u{1B}[0m) -> \u{1B}[2m\u{1B}[36mString\u{1B}[0m {",
  "      \u{1B}[34mreturn\u{1B}[39m \u{1B}[31m\"Hello, \u{1B}[39m\\(name)! This is a deliberately long line so that it has to wrap in a",
  "  narrow terminal window somewhere.\"",
  "  }",
  "",
  "  And a quote:",
  "",
  "  \u{1B}[2m▎\u{1B}[0m First paragraph of the quote with \u{1B}[1mbold\u{1B}[0m and \u{1B}[38;5;153mcode\u{1B}[39m and a \u{1B}[94m\u{1B}]8;id=16mxgfr;https://example.com/x\u{1B}\\link\u{1B}[39m\u{1B}]8;;\u{1B}\\ in it, long enough to wrap",
  "  \u{1B}[2m▎\u{1B}[0m around the terminal edge.",
  "  \u{1B}[2m▎\u{1B}[0m",
  "  \u{1B}[2m▎\u{1B}[0m Second paragraph.",
  "",
  "  \u{1B}[38;5;153mplain block\u{1B}[39m",
  "    \u{1B}[38;5;153mindented line\u{1B}[39m",
]

private let markdown = """
  Here is code:

  ```swift
  func greet(name: String) -> String {
      return "Hello, \\(name)! This is a deliberately long line so that it has to wrap in a narrow terminal window somewhere."
  }
  ```

  And a quote:

  > First paragraph of the quote with **bold** and `code` and a [link](https://example.com/x) in it, long enough to wrap around the terminal edge.
  >
  > Second paragraph.

  ```
  plain block
    indented line
  ```
  """

@MainActor
@Suite struct TerminalCopyOverlayTests {
  /// SwiftTerm parses fed bytes on another thread, so this waits until the last row shows.
  private func screen(after rows: [String]) async -> [String] {
    let view = ThemedTerminalView(frame: .zero)
    view.resize(cols: 90, rows: 20)
    view.feed(text: rows.joined(separator: "\r\n"))
    for _ in 0..<200 {
      let text = view.visibleRowsText(0..<20)
      if text.contains(where: { $0.contains("indented line") }) { return text }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return view.visibleRowsText(0..<20)
  }

  @Test func findsEveryBlockInWhatSwiftTermDrewForClaudeCode() async {
    let rows = await screen(after: claudeRows)

    let blocks = TerminalBlocks.find(rows: rows, sources: BlockSources(messages: [markdown]))

    #expect(
      blocks == [
        TerminalBlock(
          kind: .code, rows: 2...5,
          copyText: """
            func greet(name: String) -> String {
                return "Hello, \\(name)! This is a deliberately long line so that it has to wrap in a narrow terminal window somewhere."
            }
            """),
        TerminalBlock(
          kind: .quote, rows: 9...12,
          copyText: """
            First paragraph of the quote with **bold** and `code` and a [link](https://example.com/x) in it, long enough to wrap around the terminal edge.

            Second paragraph.
            """),
        TerminalBlock(kind: .code, rows: 14...15, copyText: "plain block\n  indented line"),
      ])
  }

  @Test func aQuoteWithNoTranscriptCopiesTheScreenText() async {
    let rows = await screen(after: claudeRows)

    let quote = TerminalBlocks.find(rows: rows, sources: BlockSources(messages: [])).first

    #expect(
      quote
        == TerminalBlock(
          kind: .quote, rows: 9...12,
          copyText:
            "First paragraph of the quote with bold and code and a link in it, long enough to wrap around the terminal edge.\n\nSecond paragraph."
        ))
  }

  @Test func hoveringAQuoteShowsTheButtonOnItsFirstRowAndClickingCopiesItsMarkdown() async throws {
    let board = NSPasteboard(name: NSPasteboard.Name("terminal-copy-test-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let view = PaddedTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
    window.contentView = view
    // The font of the Claude pane. The captured rows need 90 columns, or SwiftTerm wraps them.
    view.terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    view.showCopyButtons { done in done(BlockSources(messages: [markdown])) }
    let overlay = try #require(view.copyOverlay)
    overlay.pasteboard = board
    let terminal = view.terminal
    let rowCount = terminal.terminalDimensions.rows
    terminal.feed(text: claudeRows.joined(separator: "\r\n"))
    for _ in 0..<200 where !terminal.visibleRowsText(0..<rowCount).contains(where: { $0.contains("indented line") }) {
      try? await Task.sleep(for: .milliseconds(10))
    }
    let cellHeight = terminal.getOptimalFrameSize().height / CGFloat(rowCount)
    let pointer = terminal.convert(NSPoint(x: 50, y: 10.5 * cellHeight), to: nil)
    let entered = try #require(
      NSEvent.enterExitEvent(
        with: .mouseEntered, location: pointer, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))

    overlay.mouseEntered(with: entered)

    let button = overlay.button
    #expect(!button.isHidden)
    let quoteTop = terminal.convert(NSPoint(x: 0, y: 9 * cellHeight), to: view).y
    #expect(abs(button.frame.maxY - quoteTop) < 0.5)
    #expect(button.frame.maxX <= terminal.convert(terminal.bounds, to: view).maxX)

    button.performClick(nil)

    #expect(
      board.string(forType: .string)
        == "First paragraph of the quote with **bold** and `code` and a [link](https://example.com/x) in it, long enough to wrap around the terminal edge.\n\nSecond paragraph."
    )
    #expect(button.title == "Copied")
    view.showCopyButtons(nil)
  }

  @Test func theButtonTakesClicksOverTheTerminal() throws {
    let view = PaddedTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    view.showCopyButtons { done in done(BlockSources(messages: [])) }
    let button = try #require(view.copyOverlay?.button)
    button.isHidden = false
    button.frame = NSRect(x: 300, y: 150, width: 30, height: 20)

    #expect(view.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) === button)

    view.showCopyButtons(nil)
    #expect(button.superview == nil)
  }

  @Test func theButtonSitsOnTheBlocksFirstRowAtTheRightEdge() {
    #expect(TerminalCopyOverlay.topRight(row: 3, cellHeight: 15, width: 600) == NSPoint(x: 596, y: 45))
  }
}
