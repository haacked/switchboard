import AppKit
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct DraftCopyTests {
  /// Runs the body with a pasteboard of its own, so a test never reads or
  /// changes the user's clipboard. The pasteboard is released afterwards.
  func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
    let board = NSPasteboard(name: NSPasteboard.Name("draft-test-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    try body(board)
  }

  @Test func copiesTheTextAsAPlainString() {
    withPasteboard { board in
      DraftCopy.copy("Could someone review #1?", to: board)

      #expect(board.string(forType: .string) == "Could someone review #1?")
    }
  }

  @Test func replacesAnEarlierValue() {
    withPasteboard { board in
      board.clearContents()
      board.setString("an earlier copy", forType: .string)
      #expect(board.string(forType: .string) == "an earlier copy")

      DraftCopy.copy("Could someone review #1?", to: board)

      #expect(board.string(forType: .string) == "Could someone review #1?")
    }
  }

  @Test func clearsAnEarlierValueOfAnotherType() {
    withPasteboard { board in
      board.clearContents()
      board.setString("<b>earlier</b>", forType: .html)
      #expect(board.string(forType: .html) == "<b>earlier</b>")

      DraftCopy.copy("Could someone review #1?", to: board)

      #expect(board.string(forType: .html) == nil)
    }
  }

  @Test(arguments: [
    "**bold** and `code`",
    "> quoted line\n>\n> second paragraph",
    "- one\n- two\n\n1. first",
    "[a link](https://github.com/PostHog/posthog/pull/131397)",
    "```\nlet x = 1\n```",
    "Line one\n\nLine two with trailing spaces  ",
    #"say "hi" \ bye"#,
    "emoji 👋🏽 and é",
  ])
  func copiesMarkdownSourceUnchanged(_ text: String) {
    withPasteboard { board in
      DraftCopy.copy(text, to: board)

      #expect(board.string(forType: .string) == text)
    }
  }
}
