import Testing

@testable import SwitchboardApp

@Suite struct PaneFocusRules {
  @Test func aSurfaceIsFocusedOnlyWhenItsWindowIsKeyAndItHoldsTheKeyboard() {
    #expect(PaneFocus.surfaceIsFocused(windowIsKey: true, isFirstResponder: true))
    #expect(!PaneFocus.surfaceIsFocused(windowIsKey: false, isFirstResponder: true))
    #expect(!PaneFocus.surfaceIsFocused(windowIsKey: true, isFirstResponder: false))
    #expect(!PaneFocus.surfaceIsFocused(windowIsKey: false, isFirstResponder: false))
  }

  @Test func theClaudePaneTakesTheKeyboardWhenNothingHasIt() {
    #expect(PaneFocus.claimsKeyboard(isClaudePane: true, keyboardHolder: .nobody))
  }

  @Test func theShellPaneNeverTakesTheKeyboardOnItsOwn() {
    #expect(!PaneFocus.claimsKeyboard(isClaudePane: false, keyboardHolder: .nobody))
  }

  @Test func aPaneLeavesTheKeyboardWithAFieldOrTheOtherPane() {
    #expect(!PaneFocus.claimsKeyboard(isClaudePane: true, keyboardHolder: .someoneElse))
  }

  @Test func aPaneThatHoldsTheKeyboardDoesNotClaimItAgain() {
    #expect(!PaneFocus.claimsKeyboard(isClaudePane: true, keyboardHolder: .thisPane))
  }
}

@Suite struct PaneEditRules {
  @Test func copyNeedsASelection() {
    #expect(PaneEdit.isEnabled(.copy, hasSelection: true, pasteboardHasText: false))
    #expect(!PaneEdit.isEnabled(.copy, hasSelection: false, pasteboardHasText: true))
  }

  @Test func pasteNeedsTextOnThePasteboard() {
    #expect(PaneEdit.isEnabled(.paste, hasSelection: false, pasteboardHasText: true))
    #expect(!PaneEdit.isEnabled(.paste, hasSelection: true, pasteboardHasText: false))
  }

  @Test func selectAllIsAlwaysEnabled() {
    #expect(PaneEdit.isEnabled(.selectAll, hasSelection: false, pasteboardHasText: false))
  }
}

@Suite struct PaneMouseRules {
  @Test func aRightClickOpensTheMenuOnlyWhenTheProgramDidNotTakeIt() {
    #expect(PaneMouse.rightClickOpensMenu(consumedByTerminal: false))
    #expect(!PaneMouse.rightClickOpensMenu(consumedByTerminal: true))
  }

  @Test func theMouseLeavesTheGridAtAnOffscreenPosition() {
    #expect(PaneMouse.exitPosition.x < 0)
    #expect(PaneMouse.exitPosition.y < 0)
  }
}
