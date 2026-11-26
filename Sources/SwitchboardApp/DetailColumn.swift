import SwitchboardCore

/// What the window's detail column shows.
enum DetailColumn {
  case multiSelection
  case followup(SessionSummary, Followup)
  case docket(SessionSummary, DocketSummary)
  case session(SessionSummary)
  case main(MainView)

  /// True for a main view that shows a list beside the current item's detail.
  var isListDetail: Bool {
    switch self {
    case .main(.inbox), .main(.issues), .main(.loops): true
    case .main(.board), .multiSelection, .followup, .docket, .session: false
    }
  }

  var isSession: Bool {
    if case .session = self { true } else { false }
  }
}

extension BoardModel {
  /// True when the detail column shows a list and detail view that no selected session is about to replace. A selection
  /// whose session has not loaded yet still renders the main view. A refresh clears a selection that never loads.
  var showsListDetail: Bool { selection == nil && detailColumn.isListDetail }

  var detailColumn: DetailColumn {
    if showsMultiSelectionPane { return .multiSelection }
    guard let s = selected else { return .main(mainView) }
    if let f = s.followup, f.started == nil { return .followup(s, f) }
    if let d = s.docket { return .docket(s, d) }
    return .session(s)
  }
}
