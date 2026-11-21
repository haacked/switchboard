import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// What the detail column shows, with each session named by its id, so a test compares it without the session's
/// other fields.
enum ShownColumn: Equatable, CustomTestStringConvertible {
  case multiSelection
  case followup(String)
  case docket(String)
  case session(String)
  case main(MainView)

  init(_ pane: DetailColumn) {
    switch pane {
    case .multiSelection: self = .multiSelection
    case .followup(let s, _): self = .followup(s.id)
    case .docket(let s, _): self = .docket(s.id)
    case .session(let s): self = .session(s.id)
    case .main(let view): self = .main(view)
    }
  }

  var testDescription: String {
    switch self {
    case .multiSelection: "multiSelection"
    case .followup(let id): "followup(\(id))"
    case .docket(let id): "docket(\(id))"
    case .session(let id): "session(\(id))"
    case .main(let view): "main(\(view.title))"
    }
  }
}

/// `s` with a follow-up that has started.
private func withStartedFollowup(_ s: SessionSummary) -> SessionSummary {
  var s = s
  s.followup = Followup(prompt: "p")
  s.followup?.started = 1
  return s
}

/// Each model state that the detail column's precedence must tell apart. Sessions a to d are plain sessions.
enum DetailColumnShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case nothingSelected
  /// The selection names a session that sbd no longer lists.
  case staleSelection
  /// The selection names a session that sbd's removal job holds. `allSessions` has it, and `board` does not.
  case selectionHeldByRemoval
  /// The sidebar multi-selects with no `selection`, so the main view decides.
  case multiSelectionWithoutSelection
  /// The sidebar multi-selects with a `selection`, so `visibleView` is nil and the pane shows on every main view.
  case multiSelectionWithSelection
  case multiSelectionWithStaleSelection
  /// A Board click on one card puts one id in `multiSelection`. That is not a multi-selection.
  case oneCardSelectedOnBoard
  case unstartedFollowup
  case unstartedFollowupWithDocket
  case startedFollowup
  case startedFollowupWithDocket
  case docket
  case session

  var testDescription: String { rawValue }

  private static var plain: [SessionSummary] { ["a", "b", "c", "d"].map { needsItem($0) } }

  /// A model in this state, with `view` as its main view.
  @MainActor func model(_ view: MainView) throws -> BoardModel {
    let model: BoardModel
    switch self {
    case .nothingSelected, .staleSelection, .multiSelectionWithoutSelection, .multiSelectionWithSelection,
      .multiSelectionWithStaleSelection, .oneCardSelectedOnBoard, .session:
      model = appliedModel(Self.plain)
    case .selectionHeldByRemoval:
      model = appliedModel(Self.plain + [removalSession("r", .queued)])
    case .unstartedFollowup:
      model = appliedModel(Self.plain, followups: [SwitchboardAppTests.unstartedFollowup("f")])
    case .unstartedFollowupWithDocket:
      var f = docketSession("f")
      f.followup = Followup(prompt: "p")
      model = appliedModel(Self.plain + [f])
    case .startedFollowup:
      model = appliedModel(Self.plain + [withStartedFollowup(needsItem("f"))])
    case .startedFollowupWithDocket:
      model = appliedModel(Self.plain + [withStartedFollowup(docketSession("f"))])
    case .docket:
      model = appliedModel(Self.plain + [docketSession("d1")])
    }
    model.mainView = view

    switch self {
    case .nothingSelected:
      break
    case .staleSelection:
      model.selection = "gone"
      try #require(model.selected == nil)
    case .selectionHeldByRemoval:
      model.selection = "r"
      try #require(model.allSessions.contains { $0.id == "r" })
      try #require(model.selected == nil)
    case .multiSelectionWithoutSelection:
      model.multiSelection = ["a", "b"]
      try #require(model.showsMultiSelection)
    case .multiSelectionWithSelection:
      model.selection = "a"
      model.multiSelection = ["a", "b"]
      try #require(model.showsMultiSelection)
    case .multiSelectionWithStaleSelection:
      model.selection = "gone"
      model.multiSelection = ["a", "b"]
      try #require(model.showsMultiSelection)
      try #require(model.selected == nil)
    case .oneCardSelectedOnBoard:
      model.multiSelection = ["a"]
      try #require(!model.showsMultiSelection)
    case .unstartedFollowup, .unstartedFollowupWithDocket:
      model.selection = "f"
      let f = try #require(model.selected?.followup)
      try #require(f.started == nil)
    case .startedFollowup, .startedFollowupWithDocket:
      model.selection = "f"
      try #require(model.selected?.followup?.started != nil)
    case .docket:
      model.selection = "d1"
      try #require(model.selected?.docket != nil)
    case .session:
      model.selection = "a"
      try #require(model.selected?.id == "a")
    }
    try #require(model.mainView == view)
    return model
  }

  /// What the detail column shows in this state with `view` as the main view.
  func expected(_ view: MainView) -> ShownColumn {
    switch self {
    case .nothingSelected, .staleSelection, .selectionHeldByRemoval, .oneCardSelectedOnBoard: .main(view)
    case .multiSelectionWithoutSelection: view == .board ? .main(.board) : .multiSelection
    case .multiSelectionWithSelection, .multiSelectionWithStaleSelection: .multiSelection
    case .unstartedFollowup, .unstartedFollowupWithDocket: .followup("f")
    case .startedFollowup: .session("f")
    case .startedFollowupWithDocket: .docket("f")
    case .docket: .docket("d1")
    case .session: .session("a")
    }
  }
}

/// `BoardModel.detailColumn` picks what the detail column shows: the multi-selection pane, then an unstarted
/// follow-up, then a docket, then a session, then the main view.
@MainActor
@Suite struct DetailColumnPrecedence {
  @Test(arguments: DetailColumnShape.allCases, MainView.allCases)
  func showsTheExpectedPane(_ shape: DetailColumnShape, _ view: MainView) throws {
    let model = try shape.model(view)

    let pane = ShownColumn(model.detailColumn)

    #expect(pane == shape.expected(view))
  }

  @Test func anUnstartedFollowupCarriesTheSessionsFollowup() throws {
    let model = try DetailColumnShape.unstartedFollowup.model(.inbox)
    let session = try #require(model.selected)

    guard case .followup(let s, let f) = model.detailColumn else {
      Issue.record("detailColumn is \(ShownColumn(model.detailColumn).testDescription), not a followup")
      return
    }

    #expect(s.id == session.id)
    #expect(f == session.followup)
  }
}

/// `DetailColumn.isListDetail` holds only for the Inbox, the Issues view, and the Loops view.
@MainActor
@Suite struct DetailColumnListDetail {
  @Test(arguments: MainView.allCases)
  func holdsForTheMainViewsWithAList(_ view: MainView) {
    #expect(DetailColumn.main(view).isListDetail == [.inbox, .issues, .loops].contains(view))
  }

  @Test func neverHoldsForASessionOrTheMultiSelectionPane() {
    #expect(!DetailColumn.multiSelection.isListDetail)
    #expect(!DetailColumn.session(needsItem("a")).isListDetail)
  }
}

/// The sidebar rule reads `showsListDetail`, which also requires that no session is selected.
@MainActor
@Suite struct ShowsListDetail {
  @Test func holdsOnTheInboxWithNothingSelected() throws {
    #expect(try DetailColumnShape.nothingSelected.model(.inbox).showsListDetail)
  }

  /// At launch a selection names a session that sbd has not listed yet, and the Inbox renders until it loads.
  @Test(arguments: [DetailColumnShape.staleSelection, .selectionHeldByRemoval])
  func doesNotHoldWhileASelectedSessionHasNotLoaded(_ shape: DetailColumnShape) throws {
    let model = try shape.model(.inbox)

    #expect(model.detailColumn.isListDetail)
    #expect(!model.showsListDetail)
  }

  @Test func doesNotHoldOnTheBoard() throws {
    #expect(try !DetailColumnShape.nothingSelected.model(.board).showsListDetail)
  }
}
