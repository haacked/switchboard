import Foundation
import Testing

@testable import SwitchboardCore

/// The colored `prompt-empty` screen with its box line replaced by `rows`,
/// and `ruleEnd` appended to the rule above the box.
private func redrawnBox(_ rows: [String], ruleEnd: String = "") throws -> String {
  var lines = try screenFixture("prompt-empty").components(separatedBy: "\n")
  let box = lines.indices.filter { lines[$0].contains("❯\(nbsp)") }
  try #require(box.count == 1, "prompt-empty has \(box.count) box lines")
  try #require(ClaudeScreen.isRule(PromptBoxStyledText.plain(lines[box[0] - 1])))
  lines[box[0] - 1] += ruleEnd
  lines.replaceSubrange(box[0]...box[0], with: rows)
  return lines.joined(separator: "\n")
}

private func redrawnBox(_ row: String, ruleEnd: String = "") throws -> String {
  try redrawnBox([row], ruleEnd: ruleEnd)
}

private let esc = "\u{1B}"
private let nbsp = "\u{A0}"
private let dim = "\(esc)[2m"

/// An OSC 8 hyperlink around the text, ended by BEL or by ESC \.
private func link(_ text: String, bel: Bool) -> String {
  let end = bel ? "\u{07}" : "\(esc)\\"
  return "\(esc)]8;;https://example.com/2m\(end)\(text)\(esc)]8;;\(end)"
}

@Suite struct PromptBoxEmpty {
  @Test(arguments: ["prompt-placeholder", "prompt-empty", "prompt-suggestion"])
  func aBoxWithNoTypedTextIsEmpty(_ fixture: String) throws {
    #expect(ClaudeScreen.promptIsEmpty(try screenFixture(fixture)))
  }

  @Test(arguments: ["perm-after-yes", "perm-after-esc", "q-after-esc", "edit-after-esc"])
  func anEmptyBoxCapturedWithoutColorsIsEmpty(_ fixture: String) throws {
    #expect(ClaudeScreen.promptIsEmpty(try screenFixture(fixture)))
  }

  @Test func aGreyMarkerOverAnEmptyBoxIsEmpty() throws {
    #expect(ClaudeScreen.promptIsEmpty(try redrawnBox("\(esc)[38;5;246m❯\(esc)[39m\(nbsp)          ")))
  }

  @Test func dimSetOnTheRuleCarriesIntoTheBox() throws {
    #expect(ClaudeScreen.promptIsEmpty(try redrawnBox("\(esc)[39m❯\(nbsp)Try something", ruleEnd: dim)))
  }

  @Test func dimSetOnTheMarkerLineCarriesToTheNextBoxLine() throws {
    #expect(ClaudeScreen.promptIsEmpty(try redrawnBox(["\(esc)[39m❯\(nbsp)\(dim)Try one", "  and another"])))
  }

  @Test func dimUnderA256ColorGreyIsEmpty() throws {
    #expect(ClaudeScreen.promptIsEmpty(try redrawnBox("❯\(nbsp)\(dim)\(esc)[38;5;246mcommit this\(esc)[0m")))
  }

  @Test(arguments: [true, false])
  func aLinkAroundDimTextIsEmpty(_ bel: Bool) throws {
    #expect(ClaudeScreen.promptIsEmpty(try redrawnBox("❯\(nbsp)\(dim)\(link("Try this", bel: bel))\(esc)[0m")))
  }

  @Test func aCursorSequenceInsideDimTextIsEmpty() throws {
    #expect(ClaudeScreen.promptIsEmpty(try redrawnBox("❯\(nbsp)\(dim)Try\(esc)[3G this\(esc)[K")))
  }
}

@Suite struct PromptBoxHoldsADraft {
  @Test(arguments: ["prompt-typed", "prompt-multiline"])
  func aCapturedDraftIsNotEmpty(_ fixture: String) throws {
    #expect(!ClaudeScreen.promptIsEmpty(try screenFixture(fixture)))
  }

  /// Each color's operands hold a 2 that is not SGR 2.
  @Test(arguments: [
    "\(esc)[38;5;2m", "\(esc)[38;2;10;2;30m", "\(esc)[38;2;2;2;2m", "\(esc)[48;5;2m", "\(esc)[48;2;2;2;2m",
    "\(esc)[58;5;2m", "\(esc)[1;38;5;2m",
  ])
  func typedTextUnderAColorWithA2OperandIsNotEmpty(_ color: String) throws {
    #expect(!ClaudeScreen.promptIsEmpty(try redrawnBox("❯\(nbsp)\(color)half a thought\(esc)[39m")))
  }

  @Test(arguments: ["\(esc)[22m", "\(esc)[0m", "\(esc)[m", "\(esc)[0;38;5;246m"])
  func typedTextAfterDimEndsIsNotEmpty(_ reset: String) throws {
    #expect(!ClaudeScreen.promptIsEmpty(try redrawnBox("❯\(nbsp)\(dim)Try\(reset) half a thought")))
  }

  @Test func aResetBeforeTheTextStopsDimFromTheRule() throws {
    #expect(!ClaudeScreen.promptIsEmpty(try redrawnBox("\(esc)[0m❯\(nbsp)half a thought", ruleEnd: dim)))
  }

  @Test func aResetOnTheMarkerLineStopsDimOnTheNextBoxLine() throws {
    #expect(!ClaudeScreen.promptIsEmpty(try redrawnBox(["❯\(nbsp)\(dim)Try one\(esc)[0m", "  second line"])))
  }

  @Test func typedTextBeforeADimSuggestionIsNotEmpty() throws {
    #expect(!ClaudeScreen.promptIsEmpty(try redrawnBox("❯\(nbsp)half\(dim) a thought\(esc)[0m")))
  }

  /// The guard does not read a grey color as untyped text, only SGR 2.
  @Test func greyTextWithoutDimIsNotEmpty() throws {
    #expect(!ClaudeScreen.promptIsEmpty(try redrawnBox("❯\(nbsp)\(esc)[38;5;246mcommit this\(esc)[39m")))
  }

  @Test func typedTextAfterAGreyMarkerIsNotEmpty() throws {
    #expect(!ClaudeScreen.promptIsEmpty(try redrawnBox("\(esc)[38;5;246m❯\(nbsp)half a thought")))
  }

  @Test(arguments: [true, false])
  func aLinkAroundTypedTextIsNotEmpty(_ bel: Bool) throws {
    #expect(!ClaudeScreen.promptIsEmpty(try redrawnBox("❯\(nbsp)\(link("half a thought", bel: bel))")))
  }

  /// CSI 2 K erases a line. Its parameter is not SGR 2.
  @Test func aNonSGRSequenceWithA2ParameterDoesNotDim() throws {
    #expect(!ClaudeScreen.promptIsEmpty(try redrawnBox("❯\(nbsp)\(esc)[2Khalf a thought")))
  }

  @Test func aDraftLineOfRuleCharactersIsNotEmpty() throws {
    #expect(!ClaudeScreen.promptIsEmpty(try redrawnBox(["❯\(nbsp)", "  " + String(repeating: "─", count: 40)])))
  }

  @Test func aDraftOnTheThirdBoxLineIsNotEmpty() throws {
    #expect(!ClaudeScreen.promptIsEmpty(try redrawnBox(["❯\(nbsp)", "  ", "  third line"])))
  }
}

/// Without a box that shows no typed character, the guard answers not empty.
@Suite struct PromptBoxMissing {
  @Test(arguments: [
    "perm-open", "perm-down", "q-open", "edit-open", "edit-down", "edit-multi", "edit-outside", "write-open",
    "write-overwrite", "write-long", "read-open",
  ])
  func aDialogIsNotEmpty(_ fixture: String) throws {
    #expect(!ClaudeScreen.promptIsEmpty(try screenFixture(fixture)))
  }

  @Test(arguments: ["", "\n\n\n", "❯\(nbsp)\n"])
  func aScreenWithoutRulesIsNotEmpty(_ screen: String) {
    #expect(!ClaudeScreen.promptIsEmpty(screen))
  }

  @Test func aBoxWithoutItsBottomRuleIsNotEmpty() throws {
    var lines = try screenFixture("prompt-empty").components(separatedBy: "\n")
    let box = try #require(lines.firstIndex { $0.contains("❯\(nbsp)") })
    lines.removeSubrange((box + 1)...)

    #expect(!ClaudeScreen.promptIsEmpty(lines.joined(separator: "\n")))
  }

  /// Bash mode replaces the ❯ marker with !.
  @Test(arguments: ["!\(nbsp)", "!\(nbsp)ls", "!\(nbsp)\(dim)ls\(esc)[0m"])
  func bashModeIsNotEmpty(_ row: String) throws {
    #expect(!ClaudeScreen.promptIsEmpty(try redrawnBox(row)))
  }

  @Test(arguments: [
    ["❯ 1. Yes", "  2. No"],
    ["❯ \(dim)1. Yes", "  2. No\(esc)[0m"],
    ["\(dim)❯ 1. Yes", "  2. No\(esc)[0m"],
  ])
  func aMenuBetweenRulesIsNotEmpty(_ rows: [String]) throws {
    #expect(!ClaudeScreen.promptIsEmpty(try redrawnBox(rows)))
  }
}

/// `styledLines` must drop every escape sequence and keep every printed
/// character, as `capture-pane` without `-e` prints the screen.
@Suite struct PromptBoxStyledText {
  static func stripped(_ screen: String) -> String {
    screen.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
  }

  static func plain(_ screen: String) -> String {
    ClaudeScreen.styledLines(screen).map { String($0.map(\.char)) }.joined(separator: "\n")
  }

  @Test(arguments: ["prompt-placeholder", "prompt-empty", "prompt-typed", "prompt-multiline", "prompt-suggestion"])
  func aColoredFixtureReadsAsItsTextWithoutEscapes(_ fixture: String) throws {
    let screen = try screenFixture(fixture)

    #expect(Self.plain(screen) == Self.stripped(screen))
  }

  @Test(arguments: [true, false])
  func aLinkReadsAsItsText(_ bel: Bool) {
    let screen = "a \(link("b", bel: bel)) c\n\(esc)[2Kd"

    #expect(Self.plain(screen) == "a b c\nd")
  }
}
