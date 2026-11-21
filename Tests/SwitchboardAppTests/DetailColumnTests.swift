import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// What the detail column shows, named by the session's id. `DetailColumn` need not be `Equatable`, so the tests
/// compare this instead.
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

  /// What the if-chain in `ContentView.body` rendered before `detailColumn` replaced it. `detailColumn` must agree
  /// with it on every model state.
  @MainActor init(chainOf model: BoardModel) {
    if model.showsMultiSelectionPane {
      self = .multiSelection
    } else if let s = model.selected, let f = s.followup, f.started == nil {
      self = .followup(s.id)
    } else if let s = model.selected, s.docket != nil {
      self = .docket(s.id)
    } else if let s = model.selected {
      self = .session(s.id)
    } else {
      self = .main(model.mainView)
    }
  }

  /// True when the detail column shows the Inbox, the Issues view, or the Loops view.
  var isListDetail: Bool {
    switch self {
    case .main(.inbox), .main(.issues), .main(.loops): true
    default: false
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

  @Test(arguments: DetailColumnShape.allCases, MainView.allCases)
  func agreesWithTheContentViewChain(_ shape: DetailColumnShape, _ view: MainView) throws {
    let model = try shape.model(view)

    let pane = ShownColumn(model.detailColumn)

    #expect(pane == ShownColumn(chainOf: model))
  }

  @Test(arguments: MainView.allCases)
  func nothingSelectedShowsTheMainView(_ view: MainView) throws {
    let model = try DetailColumnShape.nothingSelected.model(view)

    #expect(ShownColumn(model.detailColumn) == .main(view))
  }

  /// `selected` is nil, so the old chain fell through to the main view.
  @Test(arguments: [DetailColumnShape.staleSelection, .selectionHeldByRemoval], MainView.allCases)
  func aStaleSelectionShowsTheMainView(_ shape: DetailColumnShape, _ view: MainView) throws {
    let model = try shape.model(view)

    #expect(ShownColumn(model.detailColumn) == .main(view))
  }

  @Test func multiSelectionOnTheBoardShowsTheBoard() throws {
    let model = try DetailColumnShape.multiSelectionWithoutSelection.model(.board)

    #expect(ShownColumn(model.detailColumn) == .main(.board))
  }

  @Test func multiSelectionOnTheInboxShowsTheMultiSelectionPane() throws {
    let model = try DetailColumnShape.multiSelectionWithoutSelection.model(.inbox)

    #expect(ShownColumn(model.detailColumn) == .multiSelection)
  }

  /// `visibleView` keys on `selection`, so a selection hides the Board even when `selected` is nil.
  @Test(arguments: [DetailColumnShape.multiSelectionWithSelection, .multiSelectionWithStaleSelection])
  func multiSelectionWithASelectionShowsThePaneOverTheBoard(_ shape: DetailColumnShape) throws {
    let model = try shape.model(.board)

    #expect(ShownColumn(model.detailColumn) == .multiSelection)
  }

  @Test func anUnstartedFollowupShowsTheFollowup() throws {
    let model = try DetailColumnShape.unstartedFollowup.model(.inbox)

    #expect(ShownColumn(model.detailColumn) == .followup("f"))
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

  @Test func anUnstartedFollowupWinsOverItsDocket() throws {
    let model = try DetailColumnShape.unstartedFollowupWithDocket.model(.inbox)

    #expect(ShownColumn(model.detailColumn) == .followup("f"))
  }

  @Test func aStartedFollowupShowsTheSession() throws {
    let model = try DetailColumnShape.startedFollowup.model(.inbox)

    #expect(ShownColumn(model.detailColumn) == .session("f"))
  }

  @Test func aStartedFollowupWithADocketShowsTheDocket() throws {
    let model = try DetailColumnShape.startedFollowupWithDocket.model(.inbox)

    #expect(ShownColumn(model.detailColumn) == .docket("f"))
  }

  @Test func aDocketShowsTheDocket() throws {
    let model = try DetailColumnShape.docket.model(.inbox)

    #expect(ShownColumn(model.detailColumn) == .docket("d1"))
  }

  @Test func aPlainSessionShowsTheSession() throws {
    let model = try DetailColumnShape.session.model(.inbox)

    #expect(ShownColumn(model.detailColumn) == .session("a"))
  }
}

/// Each `DetailColumn` case, built directly.
enum DetailColumnCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case multiSelection, followup, docket, session, inbox, board, issues, loops

  var testDescription: String { rawValue }

  func pane() throws -> DetailColumn {
    switch self {
    case .multiSelection: return .multiSelection
    case .followup:
      let s = unstartedFollowup("f")
      let f = try #require(s.followup)
      return .followup(s, f)
    case .docket:
      let s = docketSession("d1")
      let d = try #require(s.docket)
      return .docket(s, d)
    case .session: return .session(needsItem("a"))
    case .inbox: return .main(.inbox)
    case .board: return .main(.board)
    case .issues: return .main(.issues)
    case .loops: return .main(.loops)
    }
  }

  var isListDetail: Bool { self == .inbox || self == .issues || self == .loops }
}

/// `DetailColumn.isListDetail` holds only for the Inbox, the Issues view, and the Loops view.
@MainActor
@Suite struct DetailColumnListDetail {
  @Test(arguments: DetailColumnCase.allCases)
  func isListDetailOnlyForTheListViews(_ shape: DetailColumnCase) throws {
    let pane = try shape.pane()

    #expect(pane.isListDetail == shape.isListDetail)
  }

  @Test(arguments: MainView.allCases)
  func everyMainViewButTheBoardIsListDetail(_ view: MainView) {
    #expect(DetailColumn.main(view).isListDetail == (view != .board))
  }

  /// The sidebar rule reads `detailColumn.isListDetail`, so it must follow what renders, not `visibleView`.
  @Test(arguments: DetailColumnShape.allCases, MainView.allCases)
  func modelPaneIsListDetailMatchesWhatRenders(_ shape: DetailColumnShape, _ view: MainView) throws {
    let model = try shape.model(view)

    #expect(model.detailColumn.isListDetail == shape.expected(view).isListDetail)
  }
}
