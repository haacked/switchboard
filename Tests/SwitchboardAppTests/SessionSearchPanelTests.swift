import SwiftUI
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@Suite struct SearchPanelKeysTests {
  static let mapped: [(KeyEquivalent, SearchPanelKeys.Action)] = [
    (.downArrow, .move(1)), (.upArrow, .move(-1)), (.return, .open), (.escape, .close),
  ]

  /// Every combination of Command, Option, Control, and Shift that has at least one of them.
  static let anyOfTheFour = ReturnKeyTests.allModifiers.filter { !$0.isEmpty }

  @Test(arguments: mapped)
  func aPlainKeyDoesItsAction(_ key: KeyEquivalent, _ expected: SearchPanelKeys.Action) {
    #expect(SearchPanelKeys.action(key, modifiers: [], composing: false) == expected)
  }

  /// Menu shortcuts and ⇧-arrow text selection keep their keys.
  @Test(arguments: mapped.map(\.0), anyOfTheFour)
  func aMappedKeyWithCommandOptionControlOrShiftIsLeftAlone(_ key: KeyEquivalent, _ modifiers: EventModifiers) {
    #expect(SearchPanelKeys.action(key, modifiers: modifiers, composing: false) == nil)
  }

  /// macOS sends arrow keys with the numeric pad and function flags set.
  @Test(arguments: mapped, [EventModifiers.capsLock, .numericPad, .functionKey, [.numericPad, .functionKey]])
  func flagsOtherThanTheFourChangeNothing(
    _ mapping: (KeyEquivalent, SearchPanelKeys.Action), _ modifiers: EventModifiers
  ) {
    #expect(SearchPanelKeys.action(mapping.0, modifiers: modifiers, composing: false) == mapping.1)
  }

  /// The field's cursor keeps ← and →.
  @Test(arguments: [KeyEquivalent.leftArrow, .rightArrow])
  func leftAndRightAreLeftToTheField(_ key: KeyEquivalent) {
    #expect(SearchPanelKeys.action(key, modifiers: [], composing: false) == nil)
  }

  /// An input method that composes text commits it with Return and cancels it with Esc.
  @Test(arguments: [KeyEquivalent.return, .escape])
  func returnAndEscapeWhileComposingAreLeftToTheInputMethod(_ key: KeyEquivalent) {
    #expect(SearchPanelKeys.action(key, modifiers: [], composing: true) == nil)
  }

  @Test(arguments: [KeyEquivalent("a"), KeyEquivalent("k"), KeyEquivalent("j"), .space, .tab, .delete])
  func aKeyThatTypesOrEditsIsLeftToTheField(_ key: KeyEquivalent) {
    #expect(SearchPanelKeys.action(key, modifiers: [], composing: false) == nil)
  }

  // MARK: current

  @Test func noHighlightGivesTheFirstResult() {
    #expect(SearchPanelKeys.current(nil, in: ["a", "b"]) == "a")
  }

  @Test func aHighlightThatLeftTheResultsGivesTheFirstResult() {
    #expect(SearchPanelKeys.current("gone", in: ["a", "b"]) == "a")
  }

  @Test func aHighlightInTheResultsStays() {
    #expect(SearchPanelKeys.current("b", in: ["a", "b"]) == "b")
  }

  @Test(arguments: [nil, "a"] as [String?])
  func noResultsGiveNoHighlight(_ highlighted: String?) {
    #expect(SearchPanelKeys.current(highlighted, in: []) == nil)
  }
}

/// A working session that has no Inbox item, as after the user answered it.
private func workSession(_ id: String, state: AttentionState = .working) -> SessionSummary {
  var s = needsItem(id, state: state)
  s.triage = nil
  return s
}

private func childSession(_ id: String, of parent: String) -> SessionSummary {
  var s = workSession(id)
  s.parent = parent
  return s
}

private func docketSession(_ id: String) -> SessionSummary {
  var s = needsItem(id)
  s.cwd = ""
  s.docket = DocketSummary(DocketSession(pullRequest: "o/r#1", url: "https://github.com/o/r/pull/1"), DocketStatus())
  return s
}

/// Search and the sidebar are two ways to open a session. Each test opens one shape of session from search and
/// checks that the app selects it as a sidebar click does.
@MainActor
@Suite struct OpenFromSearchTests {
  @Test func selectsAWorkSession() {
    let model = appliedModel([workSession("a"), workSession("b")])

    model.openFromSearch("b")

    #expect(model.selection == "b")
  }

  /// `openFromBoard` sends a session with an Inbox item to the Inbox. Search selects it instead.
  @Test func selectsASessionThatHasAnInboxItemInsteadOfShowingTheInbox() throws {
    let model = appliedModel([needsItem("a"), needsItem("b")])
    model.show(.board)
    model.inboxFocus = "a"
    try #require(model.triage.contains { $0.id == "b" })

    model.openFromSearch("b")

    #expect(model.selection == "b")
    #expect(model.mainView == .board)
    #expect(model.inboxFocus == "a")
  }

  @Test func expandsTheCollapsedSectionOfTheSession() throws {
    let model = appliedModel([workSession("a")], followups: [unstartedFollowup("f")])
    try #require(!model.sidebarOrder.contains("f"))

    model.openFromSearch("f")

    #expect(model.selection == "f")
    #expect(model.sidebarOrder.contains("f"))
  }

  @Test func expandsOnlyTheSectionOfTheSession() {
    let model = appliedModel([workSession("a"), workSession("d", state: .done)])
    model.collapsed = [.notStarted, .done]

    model.openFromSearch("d")

    #expect(model.collapsed == [.notStarted])
  }

  /// The Manager has its own sidebar row, outside the sections, so search leaves the sections as they were.
  @Test func selectsTheManager() {
    let model = appliedModel([needsItem("m", manager: true, state: .working), workSession("a")])
    model.collapsed = [.notStarted, .working]

    model.openFromSearch("m")

    #expect(model.selection == "m")
    #expect(model.collapsed == [.notStarted, .working])
  }

  /// A group chat has no sidebar row, so search leaves the sections as they were.
  @Test func selectsAGroupChat() {
    let model = appliedModel([chatItem("chat", group: "g1", state: .working), workSession("a")])
    model.collapsed = [.notStarted, .working]

    model.openFromSearch("chat")

    #expect(model.selection == "chat")
    #expect(model.collapsed == [.notStarted, .working])
  }

  @Test func selectsAChildSession() {
    let model = appliedModel([workSession("p"), childSession("c", of: "p"), workSession("q")])

    model.openFromSearch("c")

    #expect(model.selection == "c")
    #expect(model.collapsed == [.notStarted])
    #expect(model.sidebarOrder.contains("c"))
  }

  @Test func selectsADocketRow() {
    let model = appliedModel([docketSession("d"), workSession("a")])
    model.show(.board)

    model.openFromSearch("d")

    #expect(model.selection == "d")
    #expect(model.mainView == .board)
  }

  @Test func closesThePanel() {
    let model = appliedModel([workSession("a")])
    model.showingSearch = true

    model.openFromSearch("a")

    #expect(!model.showingSearch)
  }

  /// The panel ranks a copy of the sessions, so a session can leave the model while the panel shows it.
  @Test func anIdThatIsGoneClosesThePanelAndKeepsTheSelection() {
    let model = appliedModel([workSession("a"), workSession("b")])
    model.selection = "a"
    model.showingSearch = true
    model.apply(.success([workSession("a")]), followups: nil)

    model.openFromSearch("b")

    #expect(!model.showingSearch)
    #expect(model.selection == "a")
  }

  @Test func anIdThatIsGoneLeavesTheSectionsAndTheListFocusAlone() {
    let model = appliedModel([workSession("a"), workSession("b")])
    model.collapsed = [.notStarted, .working]
    model.apply(.success([workSession("a")]), followups: nil)
    let requests = model.listFocusRequests

    model.openFromSearch("b")

    #expect(model.collapsed == [.notStarted, .working])
    #expect(model.listFocusRequests == requests)
  }

  /// The sidebar takes the keys, so Return there goes into the terminal, as after ⇧⌘].
  @Test func requestsListFocus() throws {
    let model = appliedModel([workSession("a")])
    model.show(.board)
    try #require(model.listFocusTarget == .board)
    let requests = model.listFocusRequests

    model.openFromSearch("a")

    #expect(model.listFocusRequests == requests + 1)
    #expect(model.listFocusTarget == .sidebar)
  }

  /// A sheet does not block the menu bar, so the menu commands that open a sheet check `presentingSheet`.
  @Test func theSearchSheetCountsAsASheet() throws {
    let model = appliedModel([workSession("a")])
    try #require(!model.presentingSheet)

    model.showingSearch = true

    #expect(model.presentingSheet)
  }
}
